alter table fauxlore.state_trade_policies
  add column if not exists transit_toll_rate numeric(5,2) not null default 5
    check(transit_toll_rate between 0 and 100);

do $$
declare fn text;
begin
  fn:=pg_get_functiondef('fauxlore.collect_third_state_trade_toll()'::regprocedure);
  if position('current_received*0.05' in fn)=0 then raise exception 'Transit formula marker missing'; end if;
  fn:=replace(fn,'current_received*0.05','current_received*transit_state.toll_rate/100');
  fn:=replace(fn,'select route_state.state_id,min(route_state.route_order) first_order',
    'select route_state.state_id,min(route_state.route_order) first_order,coalesce(max(policy.transit_toll_rate),5) toll_rate');
  fn:=replace(fn,'join fauxlore.state_profiles sp on sp.state_id=route_state.state_id',
    'join fauxlore.state_profiles sp on sp.state_id=route_state.state_id'||chr(10)||
    '    left join fauxlore.state_trade_policies policy on policy.state_id=route_state.state_id');
  execute fn;
end $$;

create or replace function fauxlore.transit_toll_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; state_key integer; rate_value numeric;
  old_rate numeric; previous fauxlore.operations; fp text; result jsonb;
begin
  actor:=fauxlore.current_account();
  if path !~ '^(my|admin)/states/[0-9]+/transit-toll$' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if path like 'admin/%' and actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  state_key:=split_part(path,'/',3)::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_key) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
    where account_id=actor.id and layer='states' and state_id=state_key) then
    raise sqlstate '42501' using message='Нет прав на государство'; end if;
  select transit_toll_rate into old_rate from fauxlore.state_trade_policies where state_id=state_key;
  if method='GET' then return jsonb_build_object('state_id',state_key,'rate',coalesce(old_rate,5),'default_rate',5,'minimum',0,'maximum',100); end if;
  if method not in ('POST','PATCH') or request_id is null or jsonb_typeof(body) is distinct from 'object'
    or body-'rate'<>'{}'::jsonb or jsonb_typeof(body->'rate') is distinct from 'number' then
    raise sqlstate '22023' using message='Укажите ставку транзита числом'; end if;
  rate_value:=(body->>'rate')::numeric;
  if rate_value<0 or rate_value>100 then raise sqlstate '22023' using message='Ставка должна быть от 0 до 100%'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=actor.id and o.request_id=transit_toll_api.request_id;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  if found then
    if previous.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  insert into fauxlore.state_trade_policies(state_id,transit_toll_rate) values(state_key,rate_value)
    on conflict(state_id) do update set transit_toll_rate=excluded.transit_toll_rate,updated_at=now();
  result:=jsonb_build_object('state_id',state_key,'rate',rate_value,'previous',coalesce(old_rate,5));
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(actor.id,transit_toll_api.request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.transit_toll_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.transit_toll_api(text,text,jsonb,uuid) to authenticated;

do $$
declare fn text;
begin
  fn:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  fn:=replace(fn,'if path ~ ''^(my|admin)/states/[0-9]+/provinces/[0-9]+/belonging$'' then',
    'if path ~ ''^(my|admin)/states/[0-9]+/transit-toll$'' then return fauxlore.transit_toll_api(path,method,body,request_id);'||chr(10)||
    '  elsif path ~ ''^(my|admin)/states/[0-9]+/provinces/[0-9]+/belonging$'' then');
  execute fn;
end $$;
notify pgrst,'reload schema';
