create table if not exists fauxlore.trade_route_transit_policies(
  agreement_id bigint not null references fauxlore.trade_agreements(id) on delete cascade,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  toll_rate numeric(5,2) not null default 5 check(toll_rate between 0 and 100),
  updated_at timestamptz not null default now(),
  primary key(agreement_id,state_id)
);
alter table fauxlore.trade_route_transit_policies enable row level security;
revoke all on fauxlore.trade_route_transit_policies from public,anon,authenticated;

-- Apply the rate configured for this exact agreement and transit state.
do $$
declare definition text;
begin
  definition:=replace(pg_get_functiondef('fauxlore.collect_third_state_trade_toll()'::regprocedure),chr(13),'');
  definition:=replace(definition,'transit_state.toll_rate',
    'coalesce((select toll_rate from fauxlore.trade_route_transit_policies where agreement_id=agreement.id and state_id=transit_state.state_id),5)');
  if position('where agreement_id=agreement.id and state_id=transit_state.state_id' in definition)=0 then
    raise exception 'Could not switch transit collector to route-specific policies';
  end if;
  execute definition;
end $$;

create or replace function fauxlore.trade_route_transit_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; state_key integer; agreement_key bigint; rate_value numeric;
  prior fauxlore.operations; fp text; result jsonb;
begin
  if path !~ '^(my|admin)/states/[0-9]+/transit-tolls$' then
    raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  actor:=fauxlore.current_account(); state_key:=split_part(path,'/',3)::integer;
  if path like 'admin/%' and actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
    where account_id=actor.id and layer='states' and state_id=state_key) then
    raise sqlstate '42501' using message='Нет прав на государство'; end if;
  if method='GET' and body='{}'::jsonb then
    return jsonb_build_object('routes',coalesce((select jsonb_agg(jsonb_build_object(
      'agreement_id',a.id,'from_state',f.name,'to_state',t.name,'status',a.status,
      'route_province_ids',a.route_province_ids,'rate',coalesce(policy.toll_rate,5))
      order by a.id)
      from fauxlore.trade_agreements a
      join fauxlore.map_categories f on f.layer='states' and f.id=a.from_state_id
      join fauxlore.map_categories t on t.layer='states' and t.id=a.to_state_id
      left join fauxlore.trade_route_transit_policies policy on policy.agreement_id=a.id and policy.state_id=state_key
      where a.status in ('pending','accepted')
        and state_key not in (a.from_state_id,a.to_state_id)
        and exists(select 1 from unnest(a.route_province_ids[2:array_length(a.route_province_ids,1)-1]) route(province_id)
          join fauxlore.provinces p on p.id=route.province_id
          left join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states'
          left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
          where coalesce(occupier.id,owner.category_id)=state_key)),'[]'::jsonb));
  end if;
  if method not in ('POST','PATCH') or request_id is null
    or jsonb_typeof(body) is distinct from 'object'
    or not (body ? 'agreement_id' and body ? 'rate')
    or (body-ARRAY['agreement_id','rate'])<>'{}'::jsonb then
    raise sqlstate '22023' using message='Укажите agreement_id и ставку'; end if;
  agreement_key:=(body->>'agreement_id')::bigint; rate_value:=(body->>'rate')::numeric;
  if rate_value<0 or rate_value>100 then raise sqlstate '22023' using message='Ставка должна быть от 0 до 100%'; end if;
  if not exists(select 1 from fauxlore.trade_agreements a where a.id=agreement_key
    and a.status in ('pending','accepted') and state_key not in(a.from_state_id,a.to_state_id)
    and exists(select 1 from unnest(a.route_province_ids[2:array_length(a.route_province_ids,1)-1]) route(province_id)
      join fauxlore.provinces p on p.id=route.province_id
      left join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states'
      left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
      where coalesce(occupier.id,owner.category_id)=state_key)) then
    raise sqlstate '22023' using message='Государство не является транзитёром на этом маршруте'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor.id::text||':'||request_id::text,0));
  select * into prior from fauxlore.operations o where o.account_id=actor.id and o.request_id=trade_route_transit_api.request_id;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  if found then
    if prior.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return prior.result;
  end if;
  insert into fauxlore.trade_route_transit_policies(agreement_id,state_id,toll_rate)
    values(agreement_key,state_key,rate_value)
    on conflict(agreement_id,state_id) do update set toll_rate=excluded.toll_rate,updated_at=now();
  result:=jsonb_build_object('agreement_id',agreement_key,'state_id',state_key,'rate',rate_value);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(actor.id,request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.trade_route_transit_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.trade_route_transit_api(text,text,jsonb,uuid) to authenticated;

-- Expose the latest settled trade income in the existing trade overview API.
do $$
declare definition text; marker text;
begin
  definition:=replace(pg_get_functiondef('fauxlore.trade_overview_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  marker:='''resources'',coalesce(';
  if position('internal_income' in definition)=0 then
    if position(marker in definition)=0 then raise exception 'Trade overview income insertion point missing'; end if;
    definition:=replace(definition,marker,
      '''internal_income'',coalesce((select sum(duty_income) from fauxlore.trade_state_resource_turns where year=latest_year and turn=latest_turn and state_id=target_state),0),'||chr(10)||
      '''zone_income'',coalesce((select sum(local_income+export_income) from fauxlore.trade_zone_income_turns where year=latest_year and turn=latest_turn and state_id=target_state),0),'||chr(10)||marker);
    execute definition;
  end if;
end $$;

do $$
declare definition text; marker text := 'elsif path=''admin/turn/test'' or path like ''admin/turn/test/%'' then';
begin
  definition:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  if position('trade_route_transit_api' in definition)=0 then
    if position(marker in definition)=0 then raise exception 'Trade API dispatch insertion point missing'; end if;
    execute replace(definition,marker,
      'elsif path ~ ''^(my|admin)/states/[0-9]+/transit-tolls$'' then return fauxlore.trade_route_transit_api(path,method,body,request_id);'||chr(10)||'  '||marker);
  end if;
end $$;
notify pgrst,'reload schema';
