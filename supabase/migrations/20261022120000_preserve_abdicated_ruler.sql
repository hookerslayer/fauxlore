create or replace function fauxlore.abdicate_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_value integer; ruler fauxlore.state_characters; previous fauxlore.operations;
  fingerprint text; result jsonb;
begin
  a:=fauxlore.current_account();
  if path !~ '^(my|admin)/states/[0-9]+/abdicate$' or method<>'POST' then raise sqlstate '22023' using message='Некорректный запрос отречения'; end if;
  state_value:=split_part(path,'/',3)::integer;
  if split_part(path,'/',1)='admin' then
    if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  elsif not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_value) then
    raise sqlstate '42501' using message='Нет доступа к этому государству'; end if;
  if body-'confirmed'<>'{}' or body->>'confirmed'<>'true' or request_id is null then raise sqlstate '22023' using message='Требуется отдельное подтверждение отречения'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=abdicate_api.request_id;
  if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
  select * into ruler from fauxlore.state_characters where state_id=state_value and is_current_ruler and alive for update;
  if not found then raise sqlstate '22023' using message='Нет действующего правителя'; end if;
  -- Temporarily use the existing death transition hook, then preserve the ruler
  -- as a living historical character rather than recording a false death.
  update fauxlore.state_characters set alive=false,died_at_turn=(select turn from fauxlore.game_calendar where singleton) where id=ruler.id;
  update fauxlore.state_characters set alive=true,died_at_turn=null where id=ruler.id;
  update fauxlore.notifications set title='Правитель отрёкся от власти',message='Правитель добровольно отрёкся. Запущена передача власти; сам персонаж остаётся жив и сохраняется в семейном реестре.'
    where account_id in(select ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=state_value)
      and kind='succession' and created_at>now()-interval '2 seconds';
  result:=jsonb_build_object('abdicated',true,'character_alive',true);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.abdicate_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.abdicate_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
 select case
  when path ~ '^(my|admin)/states/[0-9]+/abdicate$' then fauxlore.abdicate_api(path,method,body,request_id)
  when path ~ '^(my|admin)/states/[0-9]+/(succession(/events/[0-9]+/choose)?|politics|designate)$' then fauxlore.succession_api(path,method,body,request_id)
  when path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then fauxlore.character_lifecycle_api(path,method,body,request_id)
  when path ~ '^(my|admin)/states/[0-9]+/characters$' then fauxlore.characters_api(path,method,body,request_id)
  when path='my/applications' and method='GET' then fauxlore.my_applications()
  when path='my/applications' and method='POST' then fauxlore.registration_api_with_surname(path,method,body,request_id)
  when path ~ '^admin/applications/[0-9]+$' and method='PATCH' then fauxlore.registration_api_with_surname(path,method,body,request_id)
  when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%' then fauxlore.registration_api(path,method,body,request_id)
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
