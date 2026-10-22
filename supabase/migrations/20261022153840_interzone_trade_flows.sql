-- Stage 4: move residual goods between trade zones over the land adjacency graph.
-- Transport cost is a money sink; it cannot create treasury income.

create table if not exists fauxlore.trade_interzone_settlements (
  id bigint generated always as identity primary key,
  year integer not null,
  turn integer not null,
  from_zone_id integer not null,
  to_zone_id integer not null,
  resource_name text not null,
  buyer_state_id integer not null references fauxlore.state_profiles(state_id),
  seller_state_id integer not null references fauxlore.state_profiles(state_id),
  distance integer not null check(distance>0),
  quantity numeric(14,2) not null check(quantity>0),
  unit_price numeric(14,2) not null check(unit_price>=0),
  transport_cost numeric(14,2) not null check(transport_cost>=0),
  amount numeric(14,2) not null check(amount>=0),
  settled_at timestamptz not null default now(),
  check(from_zone_id<>to_zone_id),
  check(buyer_state_id<>seller_state_id),
  unique(year,turn,from_zone_id,to_zone_id,resource_name,buyer_state_id,seller_state_id)
);
alter table fauxlore.trade_interzone_settlements enable row level security;
revoke all on fauxlore.trade_interzone_settlements from public,anon,authenticated;
create index if not exists trade_interzone_turn_idx on fauxlore.trade_interzone_settlements(year desc,turn desc,from_zone_id,to_zone_id,resource_name);
create index if not exists trade_interzone_buyer_idx on fauxlore.trade_interzone_settlements(buyer_state_id,year desc,turn desc);
create index if not exists trade_interzone_seller_idx on fauxlore.trade_interzone_settlements(seller_state_id,year desc,turn desc);
drop trigger if exists trade_interzone_live_revision on fauxlore.trade_interzone_settlements;
create trigger trade_interzone_live_revision after insert or update or delete on fauxlore.trade_interzone_settlements
for each statement execute function fauxlore.bump_live_revision();

create or replace function fauxlore.clear_trade_interzone_after_budget(year_value integer,turn_value integer)
returns void language plpgsql security definer set search_path='' as $$
declare
  adjacency jsonb; zone_row record; route_row record; buyer_row record; seller_row record;
  next_count integer; base_price numeric(14,4); delivered_price numeric(14,4);
  qty numeric(14,2); amount_value numeric(14,2); seller_income numeric(14,2); fee_value numeric(14,2);
  crown numeric(14,2); report_value jsonb; state_value integer; state_name text;
  bought numeric(14,2); sold numeric(14,2); earned numeric(14,2); spent numeric(14,2);
begin
  if to_regclass('pg_temp.trade_zone_position') is null then return; end if;
  select neighbors into adjacency from fauxlore.map_adjacency where singleton;
  if adjacency is null then return; end if;

  create temporary table if not exists pg_temp.trade_route_frontier(province_id integer primary key,distance integer not null) on commit drop;
  create temporary table if not exists pg_temp.trade_route_seen(province_id integer primary key,distance integer not null) on commit drop;
  create temporary table if not exists pg_temp.trade_zone_routes(from_zone_id integer,to_zone_id integer,distance integer,primary key(from_zone_id,to_zone_id)) on commit drop;
  truncate pg_temp.trade_zone_routes;

  -- Multi-source breadth-first search from each assigned land zone. The graph
  -- is undirected even if a legacy adjacency payload contains one-way entries.
  for zone_row in select distinct category_id zone_id from fauxlore.province_values v
    join fauxlore.provinces p on p.id=v.province_id and p.kind='land' where v.layer='trade' order by category_id
  loop
    truncate pg_temp.trade_route_frontier; truncate pg_temp.trade_route_seen;
    insert into pg_temp.trade_route_frontier
      select v.province_id,0 from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id and p.kind='land'
      where v.layer='trade' and v.category_id=zone_row.zone_id;
    insert into pg_temp.trade_route_seen select * from pg_temp.trade_route_frontier;
    loop
      insert into pg_temp.trade_route_frontier
      select candidate.province_id,min(candidate.distance)
      from (
        select neighbor.id province_id,frontier.distance+1 distance
        from pg_temp.trade_route_frontier frontier
        join fauxlore.provinces current_province on current_province.id=frontier.province_id and current_province.kind='land'
        cross join lateral jsonb_array_elements_text(coalesce(adjacency->frontier.province_id::text,'[]'::jsonb)) raw(value)
        join fauxlore.provinces neighbor on neighbor.id=raw.value::integer and neighbor.kind='land'
        where not exists(select 1 from pg_temp.trade_route_seen seen where seen.province_id=neighbor.id)
        union all
        select neighbor.id,frontier.distance+1
        from pg_temp.trade_route_frontier frontier
        join fauxlore.provinces current_province on current_province.id=frontier.province_id and current_province.kind='land'
        join lateral jsonb_each(adjacency) entry(key,value) on true
        cross join lateral jsonb_array_elements_text(entry.value) raw(value)
        join fauxlore.provinces neighbor on neighbor.id=entry.key::integer and neighbor.kind='land'
        where raw.value::integer=frontier.province_id
          and not exists(select 1 from pg_temp.trade_route_seen seen where seen.province_id=neighbor.id)
      ) candidate group by candidate.province_id
      on conflict(province_id) do nothing;
      get diagnostics next_count=row_count;
      exit when next_count=0;
      insert into pg_temp.trade_route_seen select * from pg_temp.trade_route_frontier on conflict do nothing;
    end loop;
    insert into pg_temp.trade_zone_routes
    select zone_row.zone_id,destination.category_id,min(seen.distance)
    from pg_temp.trade_route_seen seen join fauxlore.province_values destination on destination.province_id=seen.province_id and destination.layer='trade'
    where destination.category_id<>zone_row.zone_id group by destination.category_id
    on conflict(from_zone_id,to_zone_id) do update set distance=least(pg_temp.trade_zone_routes.distance,excluded.distance);
  end loop;

  for route_row in
    select distinct pos.resource_name,route.from_zone_id,route.to_zone_id,route.distance
    from pg_temp.trade_zone_position pos
    join pg_temp.trade_zone_routes route on route.from_zone_id=pos.zone_id
    where exists(select 1 from pg_temp.trade_zone_position s where s.zone_id=route.from_zone_id and s.resource_name=pos.resource_name and s.balance>0)
      and exists(select 1 from pg_temp.trade_zone_position d where d.zone_id=route.to_zone_id and d.resource_name=pos.resource_name and d.balance<0)
    order by pos.resource_name,route.distance,route.from_zone_id,route.to_zone_id
  loop
    select (r->>'value')::numeric into base_price from fauxlore.economy_parameters ep cross join lateral jsonb_array_elements(ep.config->'resources') r
      where ep.singleton=true and r->>'name'=route_row.resource_name;
    if coalesce(base_price,0)<=0 then continue; end if;
    -- 2% of base value per crossed province border is paid by the buyer and
    -- removed from circulation. Seller receives the base price.
    delivered_price:=base_price*(1+.02*route_row.distance);
    for buyer_row in select state_id,balance from pg_temp.trade_zone_position
      where zone_id=route_row.to_zone_id and resource_name=route_row.resource_name and balance<0 order by state_id
    loop
      select coalesce(balance,0) into crown from fauxlore.state_treasuries where state_id=buyer_row.state_id and estate='Корона' for update;
      if coalesce(crown,0)<=0 then continue; end if;
      for seller_row in select state_id,balance from pg_temp.trade_zone_position
        where zone_id=route_row.from_zone_id and resource_name=route_row.resource_name and balance>0 and state_id<>buyer_row.state_id order by state_id
      loop
        if buyer_row.balance>=0 then exit; end if;
        select coalesce(balance,0) into crown from fauxlore.state_treasuries where state_id=buyer_row.state_id and estate='Корона' for update;
        qty:=least(-buyer_row.balance,seller_row.balance,floor(crown/delivered_price*100)/100);
        if qty<=0 then exit; end if;
        amount_value:=round(qty*delivered_price,2);
        seller_income:=round(qty*base_price,2);
        fee_value:=amount_value-seller_income;
        if amount_value>crown then qty:=greatest(0,qty-.01); amount_value:=round(qty*delivered_price,2); seller_income:=round(qty*base_price,2); fee_value:=amount_value-seller_income; end if;
        if qty<=0 or amount_value<=0 then exit; end if;
        update fauxlore.state_treasuries set balance=balance-amount_value,updated_at=now() where state_id=buyer_row.state_id and estate='Корона';
        insert into fauxlore.state_treasuries(state_id,estate,balance) values(seller_row.state_id,'Корона',0) on conflict(state_id,estate) do nothing;
        update fauxlore.state_treasuries set balance=balance+seller_income,updated_at=now() where state_id=seller_row.state_id and estate='Корона';
        insert into fauxlore.trade_interzone_settlements(year,turn,from_zone_id,to_zone_id,resource_name,buyer_state_id,seller_state_id,distance,quantity,unit_price,transport_cost,amount)
          values(year_value,turn_value,route_row.from_zone_id,route_row.to_zone_id,route_row.resource_name,buyer_row.state_id,seller_row.state_id,route_row.distance,qty,base_price,fee_value,amount_value);
        update pg_temp.trade_zone_position set balance=balance+qty where state_id=buyer_row.state_id and zone_id=route_row.to_zone_id and resource_name=route_row.resource_name;
        update pg_temp.trade_zone_position set balance=balance-qty where state_id=seller_row.state_id and zone_id=route_row.from_zone_id and resource_name=route_row.resource_name;
        buyer_row.balance:=buyer_row.balance+qty;
        seller_row.balance:=seller_row.balance-qty;
      end loop;
    end loop;
  end loop;

  update fauxlore.state_profiles sp set treasury=(select coalesce(sum(t.balance),0) from fauxlore.state_treasuries t where t.state_id=sp.state_id)
  where exists(select 1 from fauxlore.trade_interzone_settlements x where x.year=year_value and x.turn=turn_value and sp.state_id in(x.buyer_state_id,x.seller_state_id));
  select report into report_value from fauxlore.turn_economy_reports where year=year_value and turn=turn_value for update;
  for state_value in select distinct state_id from (
    select buyer_state_id state_id from fauxlore.trade_interzone_settlements where year=year_value and turn=turn_value
    union select seller_state_id from fauxlore.trade_interzone_settlements where year=year_value and turn=turn_value
  ) parties loop
    select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=state_value;
    select coalesce(sum(case when buyer_state_id=state_value then quantity else 0 end),0),
      coalesce(sum(case when seller_state_id=state_value then quantity else 0 end),0),
      coalesce(sum(case when seller_state_id=state_value then round(quantity*unit_price,2) else 0 end),0),
      coalesce(sum(case when buyer_state_id=state_value then amount else 0 end),0)
      into bought,sold,earned,spent from fauxlore.trade_interzone_settlements where year=year_value and turn=turn_value;
    select coalesce(jsonb_agg(case when (value->>'id')::integer=state_value then value||jsonb_build_object(
      'interzone_resource_units_bought',bought,'interzone_resource_units_sold',sold,
      'interzone_gold_earned',earned,'interzone_gold_spent',spent,
      'closing_treasury',(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=state_value)) else value end order by ord),'[]'::jsonb)
      into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality rows(value,ord);
  end loop;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb) where year=year_value and turn=turn_value;
end $$;
revoke all on function fauxlore.clear_trade_interzone_after_budget(integer,integer) from public,anon,authenticated;

-- Run after local markets and before their final report refresh.
do $$
declare fn text; needle text; replacement text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure),chr(13),'');
  needle:='  update fauxlore.state_profiles sp set treasury=';
  if position('clear_trade_interzone_after_budget(new.year,new.turn)' in fn)=0 then
    if position(needle in fn)=0 then raise exception 'Could not locate trade market settlement insertion point'; end if;
    replacement:='  perform fauxlore.clear_trade_interzone_after_budget(new.year,new.turn);'||chr(10)||needle;
    execute replace(fn,needle,replacement);
  end if;
end $$;

create or replace function fauxlore.trade_interzone_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts;
begin
  if path<>'my/trade-interzone' or method<>'GET' or body<>'{}'::jsonb then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  actor:=fauxlore.current_account();
  return jsonb_build_object('lines',coalesce((select jsonb_agg(jsonb_build_object('year',x.year,'turn',x.turn,'from_zone',source.name,'to_zone',destination.name,
    'resource_name',x.resource_name,'buyer',buyer.name,'seller',seller.name,'distance',x.distance,'quantity',x.quantity,'unit_price',x.unit_price,'transport_cost',x.transport_cost,'amount',x.amount)
    order by x.year desc,x.turn desc,x.distance,x.from_zone_id,x.to_zone_id,x.resource_name)
    from fauxlore.trade_interzone_settlements x
    join fauxlore.map_categories source on source.layer='trade' and source.id=x.from_zone_id
    join fauxlore.map_categories destination on destination.layer='trade' and destination.id=x.to_zone_id
    join fauxlore.map_categories buyer on buyer.layer='states' and buyer.id=x.buyer_state_id
    join fauxlore.map_categories seller on seller.layer='states' and seller.id=x.seller_state_id
    where actor.role='admin' or exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id in(x.buyer_state_id,x.seller_state_id))),'[]'::jsonb));
end $$;
revoke all on function fauxlore.trade_interzone_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.trade_interzone_api(text,text,jsonb,uuid) to anon,authenticated;

do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$elsif path='my/trade-market' then return fauxlore.trade_market_api(path,method,body,request_id);$old$;
  new_fragment:=$new$elsif path='my/trade-interzone' then return fauxlore.trade_interzone_api(path,method,body,request_id);$new$||old_fragment;
  if position('trade_interzone_api' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate inter-zone trade RPC route'; end if;
    execute replace(fn,old_fragment,new_fragment);
  end if;
end $$;

-- Include this journal in admin test-turn snapshots, cleanup, and rollback.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  execute $fn$create or replace function fauxlore.turn_snapshot_payload()
  returns jsonb language sql stable security definer set search_path='' as $body$
    select jsonb_build_object(
      'state_profiles',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_profiles x),
      'state_group_politics',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_group_politics x),
      'state_characters',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_characters x),
      'state_succession_events',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_succession_events x),
      'state_birth_events',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_birth_events x),
      'notifications',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.notifications x),
      'state_treasuries',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_treasuries x),
      'state_treasury_debts',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_treasury_debts x),
      'state_budget_ledger',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.state_budget_ledger x),
      'trade_settlements',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.trade_settlements x),
      'trade_market_settlements',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.trade_market_settlements x),
      'trade_interzone_settlements',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.trade_interzone_settlements x),
      'turn_economy_reports',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.turn_economy_reports x),
      'game_calendar',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),'[]') from fauxlore.game_calendar x)
    )
  $body$;$fn$;
  revoke all on function fauxlore.turn_snapshot_payload() from public,anon,authenticated;

  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  if position('trade_interzone_settlements' in fn)=0 then
    old_fragment:='''trade_market_settlements'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.trade_market_settlements x),';
    new_fragment:=old_fragment||'''trade_interzone_settlements'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.trade_interzone_settlements x),';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate inter-zone snapshot fragment'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='fauxlore.trade_market_settlements,fauxlore.turn_economy_reports';
    new_fragment:='fauxlore.trade_market_settlements,fauxlore.trade_interzone_settlements,fauxlore.turn_economy_reports';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate inter-zone snapshot locks'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='delete from fauxlore.trade_market_settlements where true;';
    new_fragment:=old_fragment||' delete from fauxlore.trade_interzone_settlements where true;';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate inter-zone cleanup'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='''trade_settlements'',''turn_economy_reports'',''game_calendar''';
    new_fragment:='''trade_settlements'',''trade_market_settlements'',''trade_interzone_settlements'',''turn_economy_reports'',''game_calendar''';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate inter-zone trigger restore list'; end if;
    execute replace(fn,old_fragment,new_fragment);
  end if;
end $$;

notify pgrst,'reload schema';
