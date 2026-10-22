-- Stage 3: each assigned trade zone clears local resource surpluses and deficits
-- after direct agreements, with a bounded price and cash-conserving transfers.

create table if not exists fauxlore.trade_market_settlements (
  id bigint generated always as identity primary key,
  year integer not null,
  turn integer not null,
  zone_id integer not null,
  resource_name text not null,
  buyer_state_id integer not null references fauxlore.state_profiles(state_id),
  seller_state_id integer not null references fauxlore.state_profiles(state_id),
  quantity numeric(14,2) not null check(quantity>0),
  unit_price numeric(14,2) not null check(unit_price>=0),
  amount numeric(14,2) not null check(amount>=0),
  settled_at timestamptz not null default now(),
  unique(year,turn,zone_id,resource_name,buyer_state_id,seller_state_id),
  check(buyer_state_id<>seller_state_id)
);
alter table fauxlore.trade_market_settlements enable row level security;
revoke all on fauxlore.trade_market_settlements from public,anon,authenticated;
create index if not exists trade_market_settlements_turn_idx on fauxlore.trade_market_settlements(year desc,turn desc,zone_id,resource_name);
create index if not exists trade_market_settlements_buyer_idx on fauxlore.trade_market_settlements(buyer_state_id,year desc,turn desc);
create index if not exists trade_market_settlements_seller_idx on fauxlore.trade_market_settlements(seller_state_id,year desc,turn desc);

drop trigger if exists trade_market_settlements_live_revision on fauxlore.trade_market_settlements;
create trigger trade_market_settlements_live_revision after insert or update or delete on fauxlore.trade_market_settlements
for each statement execute function fauxlore.bump_live_revision();

create or replace function fauxlore.clear_trade_zones_after_budget()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  market_row record; buyer_row record; seller_row record; buyer_remaining numeric(14,2); seller_remaining numeric(14,2);
  total_supply numeric(14,2); total_demand numeric(14,2); affordable_demand numeric(14,2); target_volume numeric(14,2);
  price_value numeric(14,2); base_value numeric(14,4); quantity_value numeric(14,2); amount_value numeric(14,2);
  crown_balance numeric(14,2); report_value jsonb; report_item jsonb; state_value integer; state_name text;
  market_sales numeric(14,2); market_purchases numeric(14,2); market_earned numeric(14,2); market_spent numeric(14,2);
begin
  create temporary table if not exists pg_temp.trade_zone_position(
    state_id integer not null, zone_id integer not null, resource_name text not null,
    balance numeric(14,2) not null, primary key(state_id,zone_id,resource_name)
  ) on commit drop;
  truncate pg_temp.trade_zone_position;

  -- Province production goes to its economic controller; consumption remains
  -- with the owning state. Only explicitly assigned land belongs to a zone.
  with cfg as (select config from fauxlore.economy_parameters where singleton=true),
  province_output as (
    select case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end state_id,
      zone.category_id zone_id,resource.name resource_name,
      round(greatest(p.population,0)::numeric*(rc.r->>'production')::numeric*
        (cfg.config#>>array['provinceModifiers',p.province_type,'production'])::numeric*
        coalesce(p.control,100)::numeric/100*(1-coalesce(owner_profile.crime,.2))*
        case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 1 end,0) amount
    from fauxlore.provinces p
    join fauxlore.province_values zone on zone.province_id=p.id and zone.layer='trade'
    join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='resources'
    join fauxlore.map_categories resource on resource.layer='resources' and resource.id=rv.category_id
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=(select v.category_id from fauxlore.province_values v where v.province_id=p.id and v.layer='states')
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    left join fauxlore.state_profiles owner_profile on owner_profile.state_id=owner.id
    cross join cfg cross join lateral jsonb_array_elements(cfg.config->'resources') rc(r)
    where p.kind='land' and resource.name=rc.r->>'name' and (case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end) is not null
  ),
  production as (select state_id,zone_id,resource_name,sum(amount)::numeric(14,2) amount from province_output group by state_id,zone_id,resource_name),
  zone_population as (
    select ov.category_id state_id,zv.category_id zone_id,sum(p.population)::numeric population
    from fauxlore.provinces p
    join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
    join fauxlore.province_values zv on zv.province_id=p.id and zv.layer='trade'
    where p.kind='land' group by ov.category_id,zv.category_id
  ),
  consumption as (
    select zp.state_id,zp.zone_id,rc.r->>'name' resource_name,
      ceil(zp.population/10*(rc.r->>'consumption')::numeric)::numeric(14,2) amount
    from zone_population zp cross join cfg cross join lateral jsonb_array_elements(cfg.config->'resources') rc(r)
    where (rc.r->>'consumption')::numeric>0
  ),
  balances as (
    select coalesce(prod.state_id,cons.state_id) state_id,coalesce(prod.zone_id,cons.zone_id) zone_id,
      coalesce(prod.resource_name,cons.resource_name) resource_name,coalesce(prod.amount,0)-coalesce(cons.amount,0) balance
    from production prod full join consumption cons using(state_id,zone_id,resource_name)
  )
  insert into pg_temp.trade_zone_position select state_id,zone_id,resource_name,balance from balances where balance<>0;

  -- Contract deliveries enter and exports leave through the endpoint zones.
  insert into pg_temp.trade_zone_position as current_position(state_id,zone_id,resource_name,balance)
  select party.state_id,party.zone_id,ts.item_name,sum(party.balance)
  from fauxlore.trade_settlements ts
  join fauxlore.trade_agreements ta on ta.id=ts.agreement_id
  cross join lateral (
    select case when ts.direction='forward' then ta.from_state_id else ta.to_state_id end state_id,
      (select category_id from fauxlore.province_values where province_id=case when ts.direction='forward' then ta.from_city_province_id else ta.to_city_province_id end and layer='trade') zone_id,
      -ts.sent balance
    where ts.item_kind='resource'
    union all
    select case when ts.direction='forward' then ta.to_state_id else ta.from_state_id end,
      (select category_id from fauxlore.province_values where province_id=case when ts.direction='forward' then ta.to_city_province_id else ta.from_city_province_id end and layer='trade'),ts.received
    where ts.item_kind='resource'
  ) party
  where ts.year=new.year and ts.turn=new.turn and party.zone_id is not null
  group by party.state_id,party.zone_id,ts.item_name
  on conflict(state_id,zone_id,resource_name) do update set balance=current_position.balance+excluded.balance;

  for market_row in
    select pos.zone_id,pos.resource_name,
      sum(greatest(pos.balance,0))::numeric(14,2) supply,
      sum(greatest(-pos.balance,0))::numeric(14,2) demand,
      (select (r->>'value')::numeric from fauxlore.economy_parameters ep cross join lateral jsonb_array_elements(ep.config->'resources') r where ep.singleton=true and r->>'name'=pos.resource_name) base_value
    from pg_temp.trade_zone_position pos group by pos.zone_id,pos.resource_name order by pos.zone_id,pos.resource_name
  loop
    total_supply:=market_row.supply; total_demand:=market_row.demand;base_value:=coalesce(market_row.base_value,0);
    if total_supply<=0 or total_demand<=0 or base_value<=0 then continue; end if;
    price_value:=round(greatest(base_value*.2,least(base_value*5,base_value*power(total_demand/total_supply,.5)))::numeric,2);
    select coalesce(sum(least(greatest(-pos.balance,0),greatest(coalesce(t.balance,0),0)/price_value)),0)::numeric(14,2)
      into affordable_demand
    from pg_temp.trade_zone_position pos left join fauxlore.state_treasuries t on t.state_id=pos.state_id and t.estate='Корона'
    where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance<0;
    target_volume:=least(total_supply,total_demand,affordable_demand);
    if target_volume<=0 then continue; end if;
    buyer_remaining:=target_volume;
    for buyer_row in
      select pos.state_id,least(-pos.balance,coalesce(t.balance,0)/price_value)::numeric(14,2) affordable
      from pg_temp.trade_zone_position pos left join fauxlore.state_treasuries t on t.state_id=pos.state_id and t.estate='Корона'
      where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance<0 order by pos.state_id
    loop
      if buyer_remaining<=0 then exit; end if;
      quantity_value:=least(buyer_row.affordable,buyer_remaining);
      select balance into crown_balance from fauxlore.state_treasuries where state_id=buyer_row.state_id and estate='Корона' for update;
      if crown_balance is null or crown_balance<=0 then continue; end if;
      if round(quantity_value*price_value,2)>crown_balance then quantity_value:=least(quantity_value,floor(crown_balance/price_value*100)/100); end if;
      if quantity_value<=0 then continue; end if;
      amount_value:=round(quantity_value*price_value,2);
      seller_remaining:=quantity_value;
      for seller_row in select state_id,balance amount from pg_temp.trade_zone_position
        where zone_id=market_row.zone_id and resource_name=market_row.resource_name and balance>0 order by state_id
      loop
        if seller_remaining<=0 then exit; end if;
        quantity_value:=least(seller_remaining,seller_row.amount);
        amount_value:=round(quantity_value*price_value,2);
        if amount_value<=0 then continue; end if;
        update fauxlore.state_treasuries set balance=balance-amount_value,updated_at=now() where state_id=buyer_row.state_id and estate='Корона';
        insert into fauxlore.state_treasuries(state_id,estate,balance) values(seller_row.state_id,'Корона',0)
          on conflict(state_id,estate) do nothing;
        update fauxlore.state_treasuries set balance=balance+amount_value,updated_at=now() where state_id=seller_row.state_id and estate='Корона';
        insert into fauxlore.trade_market_settlements(year,turn,zone_id,resource_name,buyer_state_id,seller_state_id,quantity,unit_price,amount)
          values(new.year,new.turn,market_row.zone_id,market_row.resource_name,buyer_row.state_id,seller_row.state_id,quantity_value,price_value,amount_value);
        update pg_temp.trade_zone_position set balance=balance+quantity_value where state_id=buyer_row.state_id and zone_id=market_row.zone_id and resource_name=market_row.resource_name;
        update pg_temp.trade_zone_position set balance=balance-quantity_value where state_id=seller_row.state_id and zone_id=market_row.zone_id and resource_name=market_row.resource_name;
        seller_remaining:=seller_remaining-quantity_value;buyer_remaining:=buyer_remaining-quantity_value;
      end loop;
    end loop;
  end loop;

  update fauxlore.state_profiles sp set treasury=(select coalesce(sum(t.balance),0) from fauxlore.state_treasuries t where t.state_id=sp.state_id)
  where exists(select 1 from fauxlore.trade_market_settlements ms where ms.year=new.year and ms.turn=new.turn and sp.state_id in(ms.buyer_state_id,ms.seller_state_id));

  select report into report_value from fauxlore.turn_economy_reports where year=new.year and turn=new.turn for update;
  for state_value in select distinct s from (
    select buyer_state_id s from fauxlore.trade_market_settlements where year=new.year and turn=new.turn
    union select seller_state_id from fauxlore.trade_market_settlements where year=new.year and turn=new.turn
  ) states loop
    select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=state_value;
    select coalesce(sum(case when buyer_state_id=state_value then quantity else 0 end),0),
      coalesce(sum(case when seller_state_id=state_value then quantity else 0 end),0),
      coalesce(sum(case when seller_state_id=state_value then amount else 0 end),0),
      coalesce(sum(case when buyer_state_id=state_value then amount else 0 end),0)
      into market_purchases,market_sales,market_earned,market_spent
    from fauxlore.trade_market_settlements where year=new.year and turn=new.turn;
    select coalesce(jsonb_agg(case when (value->>'id')::integer=state_value then value||jsonb_build_object(
      'market_resource_units_bought',market_purchases,'market_resource_units_sold',market_sales,
      'market_gold_earned',market_earned,'market_gold_spent',market_spent,
      'closing_treasury',(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=state_value)) else value end order by ord),'[]'::jsonb)
      into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality rows(value,ord);
  end loop;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb) where year=new.year and turn=new.turn;
  return null;
end $$;
revoke all on function fauxlore.clear_trade_zones_after_budget() from public,anon,authenticated;
drop trigger if exists turn_economy_reports_clear_trade_zones on fauxlore.turn_economy_reports;
create trigger turn_economy_reports_clear_trade_zones after insert on fauxlore.turn_economy_reports
for each row execute function fauxlore.clear_trade_zones_after_budget();

-- The market journal participates in reversible administrator test turns.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:='''trade_settlements'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.trade_settlements x),';
  new_fragment:=old_fragment||'''trade_market_settlements'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.trade_market_settlements x),';
  if position('trade_market_settlements' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn market snapshot'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='fauxlore.state_budget_ledger,fauxlore.trade_settlements,fauxlore.turn_economy_reports';
    new_fragment:='fauxlore.state_budget_ledger,fauxlore.trade_settlements,fauxlore.trade_market_settlements,fauxlore.turn_economy_reports';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn market locks'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='delete from fauxlore.trade_settlements where true;';
    new_fragment:='delete from fauxlore.trade_settlements where true; delete from fauxlore.trade_market_settlements where true;';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn market cleanup'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='''trade_settlements'',''turn_economy_reports''';
    new_fragment:='''trade_settlements'',''trade_market_settlements'',''turn_economy_reports''';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn market restore'; end if;
    execute fn;
  end if;
end $$;

create or replace function fauxlore.trade_market_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts;
begin
  if path<>'my/trade-market' or method<>'GET' or body<>'{}'::jsonb then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  actor:=fauxlore.current_account();
  return jsonb_build_object('lines',coalesce((select jsonb_agg(jsonb_build_object('year',ms.year,'turn',ms.turn,'zone',z.name,
    'resource_name',ms.resource_name,'buyer',buyer.name,'seller',seller.name,'quantity',ms.quantity,'unit_price',ms.unit_price,'amount',ms.amount)
    order by ms.year desc,ms.turn desc,ms.zone_id,ms.resource_name,ms.buyer_state_id,ms.seller_state_id)
    from fauxlore.trade_market_settlements ms
    join fauxlore.map_categories z on z.layer='trade' and z.id=ms.zone_id
    join fauxlore.map_categories buyer on buyer.layer='states' and buyer.id=ms.buyer_state_id
    join fauxlore.map_categories seller on seller.layer='states' and seller.id=ms.seller_state_id
    where actor.role='admin' or exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id in(ms.buyer_state_id,ms.seller_state_id))),'[]'::jsonb));
end $$;
revoke all on function fauxlore.trade_market_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.trade_market_api(text,text,jsonb,uuid) to anon,authenticated;

do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$elsif path in ('my/trade-agreements','my/trade-settlements') or path ~ '^(my|admin)/trade-agreements/[0-9]+/(accept|decline|cancel)$' then return fauxlore.trade_api(path,method,body,request_id);$old$;
  new_fragment:=$new$elsif path='my/trade-market' then return fauxlore.trade_market_api(path,method,body,request_id);$new$||old_fragment;
  if position('trade_market_api' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate trade market RPC route'; end if;
    execute replace(fn,old_fragment,new_fragment);
  end if;
end $$;

notify pgrst,'reload schema';
