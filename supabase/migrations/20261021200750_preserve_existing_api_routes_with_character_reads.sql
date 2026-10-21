create or replace function public.fauxlore_api(path text, method text default 'GET', body jsonb default '{}', request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$'
      then fauxlore.characters_api(path,method,body,request_id)
    when path='my/applications' and method='GET' then fauxlore.my_applications()
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
