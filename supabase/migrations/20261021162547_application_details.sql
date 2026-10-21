create or replace function fauxlore.application_details(path text,method text,body jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; app fauxlore.state_applications;
begin
  if method<>'GET' or path !~ '^my/applications/[0-9]+$' or body<>'{}'::jsonb then
    raise sqlstate '22023' using message='Некорректный запрос анкеты';
  end if;
  a:=fauxlore.current_account();
  select * into app from fauxlore.state_applications
    where id=split_part(path,'/',3)::bigint and account_id=a.id;
  if not found then raise sqlstate 'P0002' using message='Анкета не найдена'; end if;
  return jsonb_build_object('id',app.id,'status',app.status,'state_name',app.state_name,'state_color',app.state_color,
    'principles',app.principles,'ruler_name',app.ruler_name,'ruler_gender',app.ruler_gender,'ruler_title',app.ruler_title,
    'ruler_age',app.ruler_age,'race_id',app.race_id,'religion_id',app.religion_id,'history',app.history,
    'province_ids',to_jsonb(app.province_ids),'capital_province_id',app.capital_province_id,'capital_name',app.capital_name,
    'emblem_type',app.emblem_type,'emblem_base64',app.emblem_base64,'rejection_reason',app.rejection_reason,
    'state_id',app.state_id,'created_at',app.created_at,'reviewed_at',app.reviewed_at);
end $$;
revoke all on function fauxlore.application_details(text,text,jsonb) from public,anon,authenticated;
grant execute on function fauxlore.application_details(text,text,jsonb) to anon,authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%'
      then fauxlore.registration_api(path,method,body,request_id)
    when path ~ '^my/applications/[0-9]+$' then fauxlore.application_details(path,method,body)
    when path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then fauxlore.state_emblem_api(path,method,body,request_id)
    when path='game/calendar' or path='admin/turn/advance' then fauxlore.turn_api(path,method,body,request_id)
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id) end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
