-- Route profile application reads through a query that fully qualifies
-- state_name, avoiding PL/pgSQL's local-variable/column name collision.
create or replace function fauxlore.my_applications() returns jsonb
language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts;
begin
  a:=fauxlore.current_account();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select sa.id,sa.status,sa.state_name,sa.state_color,sa.principles,sa.ruler_name,sa.ruler_gender,sa.ruler_title,sa.ruler_age,
      sa.race_id,sa.religion_id,sa.history,sa.province_ids,sa.capital_province_id,sa.capital_name,sa.emblem_type,
      sa.rejection_reason,sa.state_id,sa.created_at,sa.reviewed_at
    from fauxlore.state_applications sa where sa.account_id=a.id
  ) x),'[]'::jsonb);
end $$;
revoke all on function fauxlore.my_applications() from public,anon,authenticated;
grant execute on function fauxlore.my_applications() to anon,authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case when path='my/applications' and method='GET' then fauxlore.my_applications()
    when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%'
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
