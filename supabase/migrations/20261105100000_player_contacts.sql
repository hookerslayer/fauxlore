-- Public player contacts are optional and edited only by their owner.
alter table fauxlore.accounts add column if not exists telegram_url text;
alter table fauxlore.accounts add column if not exists vk_url text;
create or replace function public.player_contacts_api(action text, target_state integer default null, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; telegram text; vk text;
begin
  actor:=fauxlore.current_account();
  if action='own' then
    return jsonb_build_object('telegram_url',actor.telegram_url,'vk_url',actor.vk_url);
  elsif action='save' then
    if jsonb_typeof(payload) is distinct from 'object' or exists(select 1 from jsonb_object_keys(payload) k where k not in ('telegram_url','vk_url')) then
      raise sqlstate '22023' using message='Неверные поля контактов'; end if;
    telegram:=nullif(btrim(coalesce(payload->>'telegram_url','')),'');
    vk:=nullif(btrim(coalesce(payload->>'vk_url','')),'');
    if (telegram is not null and (length(telegram)>200 or telegram !~* '^https://(t\.me|telegram\.me)/[a-z0-9_]{1,64}/?$'))
       or (vk is not null and (length(vk)>200 or vk !~* '^https://(www\.)?vk\.com/[a-z0-9_.]{1,100}/?$')) then
      raise sqlstate '22023' using message='Укажите ссылку https://t.me/... или https://vk.com/...'; end if;
    update fauxlore.accounts set telegram_url=telegram,vk_url=vk where id=actor.id;
    return jsonb_build_object('ok',true);
  elsif action='state' then
    if target_state is null then raise sqlstate '22023' using message='Выберите государство'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'nickname',a.nickname,'telegram_url',a.telegram_url,'vk_url',a.vk_url) order by a.nickname,a.id)
      from fauxlore.account_states s join fauxlore.accounts a on a.id=s.account_id
      where s.layer='states' and s.state_id=target_state and a.role<>'admin'),'[]'::jsonb);
  end if;
  raise sqlstate '22023' using message='Неизвестное действие';
end $function$;
revoke all on function public.player_contacts_api(text,integer,jsonb) from public,anon;
grant execute on function public.player_contacts_api(text,integer,jsonb) to authenticated;
