-- A compact public revision token lets clients avoid downloading the full map
-- until one of the map or state-data tables actually changes.
insert into fauxlore._settings(key,value_json)
values('live_revision','1'::jsonb)
on conflict(key) do nothing;

create or replace function fauxlore.bump_live_revision()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  update fauxlore._settings
    set value_json=to_jsonb(coalesce((value_json#>>'{}')::bigint,0)+1)
    where key='live_revision';
  return null;
end $$;
revoke all on function fauxlore.bump_live_revision() from public,anon,authenticated;

do $$
declare item record;
begin
  for item in
    select tablename from pg_tables
    where schemaname='fauxlore' and (
      tablename like 'state\_%' escape '\' or tablename like 'map\_%' escape '\'
      or tablename in ('provinces','province_values','account_states','game_calendar')
    )
  loop
    execute format('drop trigger if exists fauxlore_live_revision on fauxlore.%I',item.tablename);
    execute format('create trigger fauxlore_live_revision after insert or update or delete on fauxlore.%I for each statement execute function fauxlore.bump_live_revision()',item.tablename);
  end loop;
end $$;

create or replace function fauxlore.map_revision()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'data_revision',coalesce((select (value_json#>>'{}')::bigint from fauxlore._settings where key='data_revision'),0),
    'live_revision',coalesce((select (value_json#>>'{}')::bigint from fauxlore._settings where key='live_revision'),0),
    'tile_revision',coalesce((select value_json#>>'{}' from fauxlore._settings where key='tile_revision'),'')
  )
$$;
revoke all on function fauxlore.map_revision() from public,anon,authenticated;
grant execute on function fauxlore.map_revision() to anon,authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path='map/revision' and method='GET' then fauxlore.map_revision()
    when path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$'
      then fauxlore.character_lifecycle_api(path,method,body,request_id)
    when path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$'
      then fauxlore.characters_api(path,method,body,request_id)
    when path='my/marriage-offers' or path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$'
      then fauxlore.dynastic_marriage_api(path,method,body,request_id)
    when path ~ '^(my|admin)/states/[0-9]+/abdicate$'
      then fauxlore.abdicate_api(path,method,body,request_id)
    when path ~ '^(my|admin)/states/[0-9]+/(succession(/events/[0-9]+/choose)?|politics|designate)$'
      then fauxlore.succession_api(path,method,body,request_id)
    when path='my/applications' and method='GET' then fauxlore.my_applications()
    when path='my/applications' and method='POST' then fauxlore.registration_api_with_surname(path,method,body,request_id)
    when path ~ '^admin/applications/[0-9]+$' and method='PATCH' then fauxlore.registration_api_with_surname(path,method,body,request_id)
    when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%'
      then fauxlore.registration_api(path,method,body,request_id)
    when path ~ '^my/applications/[0-9]+$' then fauxlore.application_details(path,method,body)
    when path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then fauxlore.state_emblem_api(path,method,body,request_id)
    when path='game/calendar' or path='admin/turn/advance' then fauxlore.turn_api(path,method,body,request_id)
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id)
  end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';

