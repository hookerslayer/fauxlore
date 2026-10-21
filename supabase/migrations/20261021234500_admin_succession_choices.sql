create or replace function fauxlore.succession_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_value integer; event_value bigint; candidate_slot integer;
  event_row fauxlore.state_succession_events; previous fauxlore.operations; fingerprint text; actor_path text;
begin
  a:=fauxlore.current_account(); actor_path:=split_part(path,'/',1);
  if path !~ '^(my|admin)/states/[0-9]+/succession(/events/[0-9]+/choose)?$' then raise sqlstate '22023' using message='Некорректный запрос преемственности'; end if;
  state_value:=split_part(path,'/',3)::integer;
  if actor_path='admin' then
    if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  elsif not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_value) then
    raise sqlstate '42501' using message='Нет доступа к этому государству';
  end if;
  if method='GET' and path=actor_path||'/states/'||state_value||'/succession' and body='{}'::jsonb then
    select * into event_row from fauxlore.state_succession_events where state_id=state_value and resolved_at is null order by id desc limit 1;
    if not found then return jsonb_build_object('pending',false); end if;
    return jsonb_build_object('pending',true,'id',event_row.id,'event_type',event_row.event_type,'authority',event_row.authority,
      'reason',event_row.reason,'resolves_turn',event_row.resolves_turn,'chosen',event_row.chosen_at is not null,'candidates',event_row.candidates);
  end if;
  if method='POST' and path ~ '^(my|admin)/states/[0-9]+/succession/events/[0-9]+/choose$' then
    if body-'candidate'<>'{}'::jsonb or coalesce(body->>'candidate','') !~ '^[1-3]$' or request_id is null then
      raise sqlstate '22023' using message='Выберите кандидата и повторите запрос'; end if;
    event_value:=split_part(path,'/',6)::bigint;candidate_slot:=(body->>'candidate')::integer;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);
    perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=succession_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into event_row from fauxlore.state_succession_events where id=event_value and state_id=state_value and resolved_at is null for update;
    if not found then raise sqlstate 'P0002' using message='Событие передачи власти не найдено'; end if;
    if event_row.chosen_at is not null then raise sqlstate '22023' using message='Кандидат уже выбран'; end if;
    update fauxlore.state_succession_events set chosen_candidate=candidates->(candidate_slot-1),chosen_at=now() where id=event_row.id;
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,
      jsonb_build_object('chosen',candidate_slot,'resolves_turn',event_row.resolves_turn,'name',event_row.candidates->(candidate_slot-1)->>'name'));
    return (select result from fauxlore.operations where account_id=a.id and operations.request_id=succession_api.request_id);
  end if;
  raise sqlstate '22023' using message='Недопустимый запрос';
end $$;
revoke all on function fauxlore.succession_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.succession_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path ~ '^(my|admin)/states/[0-9]+/succession(/events/[0-9]+/choose)?$' then fauxlore.succession_api(path,method,body,request_id)
    when path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$'
      then fauxlore.character_lifecycle_api(path,method,body,request_id)
    when path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$'
      then fauxlore.characters_api(path,method,body,request_id)
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
