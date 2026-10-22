-- Add an administrator-only read API for the last committed turn budget report.
create or replace function fauxlore.turn_budget_report_api(path text,method text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; result jsonb;
begin
  if path<>'admin/turn/latest-report' or method<>'GET' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  a:=fauxlore.current_account();
  if a.role is distinct from 'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  select jsonb_build_object('year',r.year,'turn',r.turn,'states',r.report) into result
  from fauxlore.turn_economy_reports r order by r.year desc,r.turn desc limit 1;
  return coalesce(result,jsonb_build_object('year',null,'turn',null,'states','[]'::jsonb));
end $$;
revoke all on function fauxlore.turn_budget_report_api(text,text) from public,anon,authenticated;
grant execute on function fauxlore.turn_budget_report_api(text,text) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if path='map/revision' and method='GET' then return fauxlore.map_revision();
  elsif path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then return fauxlore.character_lifecycle_api(path,method,body,request_id);
  elsif path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$' then return fauxlore.characters_api(path,method,body,request_id);
  elsif path='my/marriage-offers' or path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then return fauxlore.dynastic_marriage_api(path,method,body,request_id);
  elsif path ~ '^(my|admin)/states/[0-9]+/abdicate$' then return fauxlore.abdicate_api(path,method,body,request_id);
  elsif path ~ '^(my|admin)/states/[0-9]+/(succession(/events/[0-9]+/choose)?|politics|designate)$' then return fauxlore.succession_api(path,method,body,request_id);
  elsif path='my/applications' and method='GET' then return fauxlore.my_applications();
  elsif path='my/applications' and method='POST' then return fauxlore.registration_api_with_surname(path,method,body,request_id);
  elsif path ~ '^admin/applications/[0-9]+$' and method='PATCH' then return fauxlore.registration_api_with_surname(path,method,body,request_id);
  elsif path='my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%' then return fauxlore.registration_api(path,method,body,request_id);
  elsif path ~ '^my/applications/[0-9]+$' then return fauxlore.application_details(path,method,body);
  elsif path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then return fauxlore.state_emblem_api(path,method,body,request_id);
  elsif path ~ '^admin/states/[0-9]+/army$' then return fauxlore.army_budget_api(path,method,body,request_id);
  elsif path='admin/turn/latest-report' then return fauxlore.turn_budget_report_api(path,method);
  elsif path='game/calendar' or path='admin/turn/advance' then return fauxlore.turn_api(path,method,body,request_id);
  elsif path='admin/states' then return fauxlore.state_api(path,method,body,request_id);
  elsif path='my/states' or path like 'admin/states/%' then return fauxlore.game_state_api(path,method,body,request_id);
  else return fauxlore.api(path,method,body,request_id); end if;
end $$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
