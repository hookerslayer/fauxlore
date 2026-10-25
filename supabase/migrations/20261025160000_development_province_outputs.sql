CREATE OR REPLACE FUNCTION fauxlore.apply_turn_population_and_recruit_growth()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare state_row record; province_row record; cfg jsonb; indicators jsonb; report_value jsonb; item jsonb;
  province_growth integer; population_growth bigint; recruit_growth bigint; province_changes jsonb;
begin
  select report into report_value from fauxlore.turn_economy_reports where year=new.year and turn=new.turn for update;
  select config into cfg from fauxlore.economy_parameters where singleton;
  for state_row in select state_id,recruits from fauxlore.state_profiles order by state_id loop
    select x.value->'indicators_at_turn_start' into indicators
      from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality x(value,ord)
      where x.value->>'id' ~ '^\d+$' and (x.value->>'id')::integer=state_row.state_id;
    if indicators is null then indicators:=fauxlore.state_indicators(state_row.state_id); end if;
    population_growth:=0; province_changes:='[]'::jsonb;
    for province_row in
      select p.id,p.population,p.development,race.name race,rv.category_id race_id,relv.category_id religion_id
      from fauxlore.provinces p
      join fauxlore.province_values sv on sv.province_id=p.id and sv.layer='states' and sv.category_id=state_row.state_id
      left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
      left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id
      left join fauxlore.province_values relv on relv.province_id=p.id and relv.layer='religions'
      where p.kind='land' order by p.id
    loop
      if cfg#>>array['raceGrowthModifiers',province_row.race] is null then continue; end if;
      province_growth:=round(province_row.population*.015*(cfg#>>array['raceGrowthModifiers',province_row.race])::numeric
        *(indicators->>'urbanization_growth_multiplier')::numeric
        *(indicators->>'crime_population_growth_multiplier')::numeric
        *greatest(0,coalesce(province_row.development,100))::numeric/100
        *fauxlore.group_status_effect(state_row.state_id,'race',province_row.race_id,'population')
        *fauxlore.group_status_effect(state_row.state_id,'religion',province_row.religion_id,'population'),0)::integer;
      if province_growth>0 then
        if province_row.population::bigint+province_growth>2147483647 then raise sqlstate '22003' using message='Прирост населения превышает предел численности провинции'; end if;
        update fauxlore.provinces set population=population+province_growth where id=province_row.id;
        population_growth:=population_growth+province_growth;
        province_changes:=province_changes||jsonb_build_array(jsonb_build_object('province_id',province_row.id,'before',province_row.population,
          'growth',province_growth,'after',province_row.population+province_growth));
      end if;
    end loop;
    recruit_growth:=coalesce((indicators->>'recruit_growth')::bigint,0);
    if recruit_growth>0 then
      if state_row.recruits::bigint+recruit_growth>2147483647 then raise sqlstate '22003' using message='Прирост рекрутов превышает предел резерва государства'; end if;
      update fauxlore.state_profiles set recruits=recruits+recruit_growth where state_id=state_row.state_id;
    end if;
    item:=jsonb_build_object('population_growth_credited',population_growth,'province_population_changes',province_changes,
      'recruits_before',state_row.recruits,'recruit_growth_credited',recruit_growth,'recruits_after',state_row.recruits+recruit_growth);
    select coalesce(jsonb_agg(case when x.value->>'id' ~ '^\d+$' and (x.value->>'id')::integer=state_row.state_id then x.value||item else x.value end order by x.ord),'[]'::jsonb)
      into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality x(value,ord);
  end loop;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb) where year=new.year and turn=new.turn;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION fauxlore.clear_trade_zones_after_budget()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  market_row record; buyer_row record; seller_row record; buyer_remaining numeric(14,2); seller_remaining numeric(14,2);
  total_supply numeric(14,2); total_demand numeric(14,2); affordable_demand numeric(14,2); target_volume numeric(14,2);
  price_value numeric(14,2); base_value numeric(14,4); quantity_value numeric(14,2); amount_value numeric(14,2); buyer_quantity numeric(14,2); seller_pool numeric(14,2);
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
        coalesce(p.control,100)::numeric/100*greatest(0,coalesce(p.development,100))::numeric/100*(1-coalesce(owner_profile.crime,.2))*
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

  create temporary table if not exists pg_temp.trade_open_position (like pg_temp.trade_zone_position including all) on commit drop;
  truncate pg_temp.trade_open_position;
  insert into pg_temp.trade_open_position select * from pg_temp.trade_zone_position;
  for market_row in
    select pos.zone_id,pos.resource_name,
      sum(greatest(pos.balance,0))::numeric(14,2) supply,
      sum(greatest(-pos.balance,0))::numeric(14,2) demand,
      (select (r->>'value')::numeric from fauxlore.economy_parameters ep cross join lateral jsonb_array_elements(ep.config->'resources') r where ep.singleton=true and r->>'name'=pos.resource_name) base_value
    from pg_temp.trade_zone_position pos group by pos.zone_id,pos.resource_name order by pos.zone_id,pos.resource_name
  loop
    total_supply:=market_row.supply; total_demand:=market_row.demand;base_value:=coalesce(market_row.base_value,0);
    if total_supply<=0 or total_demand<=0 then continue; end if;
    price_value:=round(greatest(base_value*(select (config#>>'{tradeMarket,minPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true),
      least(base_value*(select (config#>>'{tradeMarket,maxPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true),
        base_value*power(total_demand/total_supply,(select (config#>>'{tradeMarket,priceElasticity}')::numeric from fauxlore.economy_parameters where singleton=true))))::numeric,2);
    null;
    affordable_demand:=total_demand;
    target_volume:=least(total_supply,total_demand,affordable_demand);
    if target_volume<=0 then continue; end if;
    buyer_remaining:=target_volume;
    for buyer_row in select a.state_id,a.allocation affordable,a.influence buyer_influence
      from fauxlore.allocate_trade_market_demand(market_row.zone_id,market_row.resource_name,target_volume) a order by a.state_id
    loop
      if buyer_remaining<=0 then exit; end if;
      quantity_value:=least(buyer_row.affordable,buyer_remaining);
      if quantity_value<=0 then continue; end if; amount_value:=0;
      buyer_quantity:=quantity_value; seller_remaining:=buyer_quantity; select coalesce(sum(pos.balance),0) into seller_pool from pg_temp.trade_zone_position pos where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance>0;
      for seller_row in select state_id,balance amount,row_number() over(order by state_id) seq,count(*) over() total from pg_temp.trade_zone_position
        where zone_id=market_row.zone_id and resource_name=market_row.resource_name and balance>0 order by state_id
      loop
        if seller_remaining<=0 then exit; end if;
        if seller_row.seq=seller_row.total then quantity_value:=least(seller_remaining,seller_row.amount);else quantity_value:=least(seller_remaining,seller_row.amount,round(buyer_quantity*seller_row.amount/nullif(seller_pool,0),2));end if;
        amount_value:=0;
        if quantity_value<=0 then continue; end if;
        insert into fauxlore.trade_market_settlements(year,turn,zone_id,resource_name,buyer_state_id,seller_state_id,quantity,unit_price,amount,buyer_influence)
          values(new.year,new.turn,market_row.zone_id,market_row.resource_name,buyer_row.state_id,seller_row.state_id,quantity_value,0,0,buyer_row.buyer_influence);
        update pg_temp.trade_zone_position set balance=balance+quantity_value where state_id=buyer_row.state_id and zone_id=market_row.zone_id and resource_name=market_row.resource_name;
        update pg_temp.trade_zone_position set balance=balance-quantity_value where state_id=seller_row.state_id and zone_id=market_row.zone_id and resource_name=market_row.resource_name;
        seller_remaining:=seller_remaining-quantity_value;buyer_remaining:=buyer_remaining-quantity_value;
      end loop;
    end loop;
  end loop;

  update fauxlore.state_group_politics gp set loyalty=greatest(0,least(1,gp.loyalty+(15-coalesce(policy.internal_duty_rate,15))/400)) from fauxlore.state_trade_policies policy where gp.state_id=policy.state_id and gp.group_type='estate' and gp.group_key='Горожане';
  perform fauxlore.clear_trade_interzone_after_budget(new.year,new.turn);
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
      'market_gold_earned',market_earned,'market_gold_spent',market_spent,'market_duty_income',(select coalesce(sum(internal_duty_amount),0) from fauxlore.trade_market_settlements where year=new.year and turn=new.turn and buyer_state_id=state_value),
      'closing_treasury',(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=state_value)) else value end order by ord),'[]'::jsonb)
      into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality rows(value,ord);
  end loop;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb) where year=new.year and turn=new.turn;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION fauxlore.finish_trade_value_turn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  rec record; zone_row record; participant record; total_influence numeric; allocated numeric;
  local_value numeric; export_value numeric; share_value numeric; n integer;
  report_value jsonb; state_row jsonb; total_duty numeric; total_market numeric;
begin
  if to_regclass('pg_temp.trade_open_position') is null then return null; end if;

  -- Reconstruct the same provincial production and zonal consumption used by
  -- clear_trade_zones_after_budget, then aggregate by state and resource.
  with cfg as (select config from fauxlore.economy_parameters where singleton=true),
  produced as (
    select case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end state_id,
      r.name resource_name,
      round(greatest(p.population,0)::numeric*(res.r->>'production')::numeric*
        (cfg.config#>>array['provinceModifiers',p.province_type,'production'])::numeric*
        coalesce(p.control,100)::numeric/100*greatest(0,coalesce(p.development,100))::numeric/100*(1-coalesce(owner_profile.crime,.2))*
        case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 1 end,0) amount
    from fauxlore.provinces p
    join fauxlore.province_values zv on zv.province_id=p.id and zv.layer='trade'
    join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='resources'
    join fauxlore.map_categories r on r.layer='resources' and r.id=rv.category_id
    left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    left join fauxlore.state_profiles owner_profile on owner_profile.state_id=owner.id
    cross join cfg cross join lateral jsonb_array_elements(cfg.config->'resources') res(r)
    where p.kind='land' and r.name=res.r->>'name'
  ), population as (
    select ov.category_id state_id,zv.category_id zone_id,sum(p.population)::numeric population
    from fauxlore.provinces p join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
    join fauxlore.province_values zv on zv.province_id=p.id and zv.layer='trade'
    where p.kind='land' group by ov.category_id,zv.category_id
  ), consumed as (
    select pop.state_id,res.r->>'name' resource_name,
      sum(ceil(pop.population/10*(res.r->>'consumption')::numeric)) amount
    from population pop cross join cfg cross join lateral jsonb_array_elements(cfg.config->'resources') res(r)
    where (res.r->>'consumption')::numeric>0 group by pop.state_id,res.r->>'name'
  ), contracts as (
    select party.state_id,ts.item_name resource_name,
      sum(party.imported) imported,sum(party.exported) exported
    from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id
    cross join lateral (values
      (case when ts.direction='forward' then ta.from_state_id else ta.to_state_id end,0::numeric,ts.sent),
      (case when ts.direction='forward' then ta.to_state_id else ta.from_state_id end,ts.received,0::numeric)
    ) party(state_id,imported,exported)
    where ts.year=new.year and ts.turn=new.turn and ts.item_kind='resource'
    group by party.state_id,ts.item_name
  ), zonal as (
    select state_id,resource_name,sum(imported) imported,sum(exported) exported from (
      select buyer_state_id state_id,resource_name,quantity imported,0::numeric exported
        from fauxlore.trade_market_settlements where year=new.year and turn=new.turn
      union all select seller_state_id,resource_name,0,quantity
        from fauxlore.trade_market_settlements where year=new.year and turn=new.turn
      union all select buyer_state_id,resource_name,quantity,0
        from fauxlore.trade_interzone_settlements where year=new.year and turn=new.turn
      union all select seller_state_id,resource_name,0,quantity
        from fauxlore.trade_interzone_settlements where year=new.year and turn=new.turn
    ) f group by state_id,resource_name
  ), states as (
    select state_id,resource_name from produced union select state_id,resource_name from consumed
    union select state_id,resource_name from contracts union select state_id,resource_name from zonal
  )
  insert into fauxlore.trade_state_resource_turns
    (year,turn,state_id,resource_name,production,consumption,contract_import,contract_export,zone_import,zone_export,base_price,dynamic_price,internal_quantity,turnover,duty_income)
  select new.year,new.turn,s.state_id,s.resource_name,
    coalesce(p.amount,0),coalesce(c.amount,0),coalesce(ct.imported,0),coalesce(ct.exported,0),
    coalesce(z.imported,0),coalesce(z.exported,0),(res.r->>'value')::numeric,
    fauxlore.trade_dynamic_price((res.r->>'value')::numeric,
      case s.resource_name when 'Зерно' then .4 when 'Лес' then .6 when 'Морепродукты' then .7
      when 'Животноводство' then .8 when 'Соль' then .4 when 'Хлопок' then 1
      when 'Металлы' then 1.2 when 'Мех' then 1.5 when 'Красители' then 1.9
      when 'Табак' then 1.3 when 'Селитра' then 2.2 when 'Фрукты' then 1.4
      when 'Сахар' then 1.7 when 'Чай' then 1.6 when 'Кофе' then 1.6
      when 'Шёлк' then 2.5 when 'Жемчуг' then 3 when 'Драгоценные металлы' then 2.8
      when 'Эфемера' then 4.5 else 0 end,
      coalesce(c.amount,0),greatest(coalesce(p.amount,0)+coalesce(ct.imported,0)-coalesce(ct.exported,0),0)),
    least(coalesce(c.amount,0),greatest(coalesce(p.amount,0)+coalesce(ct.imported,0)-coalesce(ct.exported,0),0)),
    0,0
  from states s left join (select state_id,resource_name,sum(amount) amount from produced group by state_id,resource_name) p using(state_id,resource_name)
    left join consumed c using(state_id,resource_name) left join contracts ct using(state_id,resource_name)
    left join zonal z using(state_id,resource_name)
    cross join cfg cross join lateral jsonb_array_elements(cfg.config->'resources') res(r)
  where s.state_id is not null and res.r->>'name'=s.resource_name and (res.r->>'value')::numeric>0
  on conflict(year,turn,state_id,resource_name) do nothing;

  update fauxlore.trade_state_resource_turns sr set
    turnover=round(sr.internal_quantity*sr.dynamic_price,2),
    duty_income=round(sr.internal_quantity*sr.dynamic_price*
      coalesce((select internal_duty_rate from fauxlore.state_trade_policies where state_id=sr.state_id),15)/100,2)
  where sr.year=new.year and sr.turn=new.turn;

  for rec in select zone_id,resource_name,
      sum(greatest(balance,0)) local_supply,sum(greatest(-balance,0)) demand
    from pg_temp.trade_open_position group by zone_id,resource_name loop
    insert into fauxlore.trade_zone_resource_turns
      (year,turn,zone_id,resource_name,demand,local_supply,incoming,local_quantity,exported,base_price,dynamic_price,local_turnover,incoming_turnover)
    select new.year,new.turn,rec.zone_id,rec.resource_name,rec.demand,rec.local_supply,
      coalesce((select sum(quantity) from fauxlore.trade_interzone_settlements
        where year=new.year and turn=new.turn and to_zone_id=rec.zone_id and resource_name=rec.resource_name),0),
      coalesce((select sum(quantity) from fauxlore.trade_market_settlements
        where year=new.year and turn=new.turn and zone_id=rec.zone_id and resource_name=rec.resource_name),0),
      coalesce((select sum(quantity) from fauxlore.trade_interzone_settlements
        where year=new.year and turn=new.turn and from_zone_id=rec.zone_id and resource_name=rec.resource_name),0),
      (r->>'value')::numeric,
      fauxlore.trade_dynamic_price((r->>'value')::numeric,
        case rec.resource_name when 'Зерно' then .4 when 'Лес' then .6 when 'Морепродукты' then .7
        when 'Животноводство' then .8 when 'Соль' then .4 when 'Хлопок' then 1
        when 'Металлы' then 1.2 when 'Мех' then 1.5 when 'Красители' then 1.9
        when 'Табак' then 1.3 when 'Селитра' then 2.2 when 'Фрукты' then 1.4
        when 'Сахар' then 1.7 when 'Чай' then 1.6 when 'Кофе' then 1.6
        when 'Шёлк' then 2.5 when 'Жемчуг' then 3 when 'Драгоценные металлы' then 2.8
        when 'Эфемера' then 4.5 else 0 end,
        rec.demand,rec.local_supply+coalesce((select sum(quantity) from fauxlore.trade_interzone_settlements
          where year=new.year and turn=new.turn and to_zone_id=rec.zone_id and resource_name=rec.resource_name),0)),0,0
    from fauxlore.economy_parameters ep cross join lateral jsonb_array_elements(ep.config->'resources') r
    where ep.singleton=true and r->>'name'=rec.resource_name and (r->>'value')::numeric>0;
  end loop;
  update fauxlore.trade_zone_resource_turns zr set
    local_turnover=round(zr.local_quantity*zr.dynamic_price,2),
    incoming_turnover=round(zr.incoming*zr.dynamic_price,2)
  where zr.year=new.year and zr.turn=new.turn;

  -- The transfer's price is the destination's price; its income belongs to
  -- the origin zone. Persist unit price and turnover for the flow journal.
  update fauxlore.trade_interzone_settlements flow set
    unit_price=dest.dynamic_price,amount=round(flow.quantity*dest.dynamic_price,2)
  from fauxlore.trade_zone_resource_turns dest
  where flow.year=new.year and flow.turn=new.turn
    and dest.year=flow.year and dest.turn=flow.turn and dest.zone_id=flow.to_zone_id
    and dest.resource_name=flow.resource_name;
  update fauxlore.trade_market_settlements flow set
    unit_price=zone.dynamic_price,amount=round(flow.quantity*zone.dynamic_price,2)
  from fauxlore.trade_zone_resource_turns zone
  where flow.year=new.year and flow.turn=new.turn
    and zone.year=flow.year and zone.turn=flow.turn and zone.zone_id=flow.zone_id
    and zone.resource_name=flow.resource_name;

  for zone_row in select distinct zone_id from fauxlore.trade_zone_resource_turns
    where year=new.year and turn=new.turn loop
    select coalesce(sum(local_turnover),0) into local_value
      from fauxlore.trade_zone_resource_turns where year=new.year and turn=new.turn and zone_id=zone_row.zone_id;
    select coalesce(sum(amount),0) into export_value
      from fauxlore.trade_interzone_settlements where year=new.year and turn=new.turn and from_zone_id=zone_row.zone_id;
    select coalesce(sum(fauxlore.trade_zone_influence(sp.state_id,zone_row.zone_id)),0) into total_influence
      from fauxlore.state_profiles sp;
    allocated:=0;n:=0;
    for participant in
      select state_id,fauxlore.trade_zone_influence(state_id,zone_row.zone_id) influence
      from fauxlore.state_profiles
      order by influence desc,state_id
    loop
      if participant.influence<=0 or total_influence<=0 then continue; end if;
      n:=n+1;
      share_value:=round(local_value*participant.influence/total_influence,2);
      insert into fauxlore.trade_zone_income_turns
        values(new.year,new.turn,zone_row.zone_id,participant.state_id,participant.influence,share_value,
          round(export_value*participant.influence/total_influence,2));
    end loop;
    -- Assign cent remainders to the strongest participant.
    if n>0 then
      update fauxlore.trade_zone_income_turns zi set
        local_income=local_income+local_value-(select sum(local_income) from fauxlore.trade_zone_income_turns
          where year=new.year and turn=new.turn and zone_id=zone_row.zone_id),
        export_income=export_income+export_value-(select sum(export_income) from fauxlore.trade_zone_income_turns
          where year=new.year and turn=new.turn and zone_id=zone_row.zone_id)
      where (zi.year,zi.turn,zi.zone_id,zi.state_id)=
        (select year,turn,zone_id,state_id from fauxlore.trade_zone_income_turns
          where year=new.year and turn=new.turn and zone_id=zone_row.zone_id
          order by influence desc,state_id limit 1);
    end if;
  end loop;

  -- Money is created only for the levy and each zone's fulfilled turnover.
  for rec in select state_id,sum(duty_income) duty from fauxlore.trade_state_resource_turns
    where year=new.year and turn=new.turn group by state_id loop
    select coalesce(sum(local_income+export_income),0) into total_market
      from fauxlore.trade_zone_income_turns where year=new.year and turn=new.turn and state_id=rec.state_id;
    if rec.duty+total_market<>0 then
      insert into fauxlore.state_treasuries(state_id,estate,balance) values(rec.state_id,'Корона',rec.duty+total_market)
        on conflict(state_id,estate) do update set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
    end if;
  end loop;
  update fauxlore.state_profiles sp set treasury=
    (select coalesce(sum(balance),0) from fauxlore.state_treasuries t where t.state_id=sp.state_id)
  where exists(select 1 from fauxlore.trade_state_resource_turns sr
    where sr.year=new.year and sr.turn=new.turn and sr.state_id=sp.state_id);
  select report into report_value from fauxlore.turn_economy_reports where year=new.year and turn=new.turn for update;
  select coalesce(jsonb_agg(value||jsonb_build_object(
    'trade_internal_income',(select coalesce(sum(duty_income),0) from fauxlore.trade_state_resource_turns
      where year=new.year and turn=new.turn and state_id=(value->>'id')::integer),
    'trade_zone_income',(select coalesce(sum(local_income+export_income),0) from fauxlore.trade_zone_income_turns
      where year=new.year and turn=new.turn and state_id=(value->>'id')::integer),
    'closing_treasury',(select coalesce(sum(balance),0) from fauxlore.state_treasuries
      where state_id=(value->>'id')::integer)) order by ord),'[]'::jsonb)
    into report_value from jsonb_array_elements(report_value) with ordinality rows(value,ord);
  update fauxlore.turn_economy_reports set report=report_value where year=new.year and turn=new.turn;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION fauxlore.state_population_growth(target_state integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with cfg as (select config from fauxlore.economy_parameters where singleton),
owned as (select p.*,race.name race,rv.category_id race_id from fauxlore.provinces p
join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=target_state
left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id left join fauxlore.province_values relv on relv.province_id=p.id and relv.layer='religions' where p.kind='land'),
urban as (select coalesce(sum(population*case province_type when 'Столичная' then .35 when 'Городская' then .2 else 0 end)/nullif(sum(population),0),0) ratio from owned),
modifiers as (select greatest(1-(cfg.config#>>'{stateEffects,urbanizationPenaltyCap}')::numeric,
  1-greatest(0,ratio-(cfg.config#>>'{stateEffects,urbanizationThreshold}')::numeric)*(cfg.config#>>'{stateEffects,urbanizationPenaltySlope}')::numeric) urban,
  1-sp.crime*(cfg.config#>>'{stateEffects,crimePopulationPenalty}')::numeric crime,sp.crime crime_rate,sp.corruption
from urban cross join cfg join fauxlore.state_profiles sp on sp.state_id=target_state),
growth as (select case when count(*) filter(where cfg.config#>>array['raceGrowthModifiers',p.race] is null)>0 then null
else coalesce(sum(round(p.population*.015*(cfg.config#>>array['raceGrowthModifiers',p.race])::numeric*m.urban*m.crime*greatest(0,coalesce(p.development,100))::numeric/100*fauxlore.group_status_effect(target_state,'race',p.race_id,'population')*fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'population'),0)),0) end value
from owned p cross join modifiers m cross join cfg)
select jsonb_build_object('urbanization_growth_multiplier',m.urban,'crime_population_growth_multiplier',m.crime,
  'population_growth',g.value,'crime',m.crime_rate,'corruption',m.corruption) from modifiers m cross join growth g
$function$;

CREATE OR REPLACE FUNCTION fauxlore.trade_resource_surplus(state_value integer, resource_value text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with cfg as (select config from fauxlore.economy_parameters where singleton=true),
  resource_config as (select r from cfg cross join lateral jsonb_array_elements(cfg.config->'resources') r where r->>'name'=resource_value limit 1),
  owned_population as (
    select coalesce(sum(p.population),0)::numeric amount from fauxlore.provinces p
    join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states' and owner.category_id=state_value
    where p.kind='land'
  ),
  output as (
    select coalesce(sum(round(greatest(p.population,0)::numeric*(rc.r->>'production')::numeric*
      (cfg.config#>>array['provinceModifiers',p.province_type,'production'])::numeric*
      coalesce(p.control,100)::numeric/100*greatest(0,coalesce(p.development,100))::numeric/100*(1-coalesce(owner_profile.crime,.2))*
      case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,''))
        then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 1 end,0)),0)::numeric amount
    from fauxlore.provinces p
    join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='resources'
    join fauxlore.map_categories resource on resource.layer='resources' and resource.id=rv.category_id and resource.name=resource_value
    left join fauxlore.province_values owner_value on owner_value.province_id=p.id and owner_value.layer='states'
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=owner_value.category_id
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    left join fauxlore.state_profiles owner_profile on owner_profile.state_id=owner.id
    cross join cfg cross join resource_config rc
    where p.kind='land' and (case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end)=state_value
  )
  select coalesce(output.amount,0)-ceil(owned_population.amount/10*(resource_config.r->>'consumption')::numeric)
  from output cross join owned_population cross join resource_config
$function$;

CREATE OR REPLACE FUNCTION fauxlore.report_food_security_after_turn()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  state_row record;
  report_value jsonb;
  state_item jsonb;
  required_units numeric(14,2);
  deficit_units numeric(14,2);
  coverage_pct numeric(7,2);
  state_crime numeric(5,4); indicators jsonb; steps jsonb; next_crime numeric; corruption_steps jsonb; next_corruption numeric; effects_config jsonb;
begin
  select r.report into report_value
  from fauxlore.turn_economy_reports r
  where r.year=new.year and r.turn=new.turn
  for update;

  for state_row in
    select sp.state_id,coalesce(mc.name,'Государство '||sp.state_id) name,coalesce(sp.crime,.2) crime
    from fauxlore.state_profiles sp
    left join fauxlore.map_categories mc on mc.layer='states' and mc.id=sp.state_id
    order by sp.state_id
  loop
    state_crime:=state_row.crime;
    indicators:=fauxlore.state_indicators(state_row.state_id);
    select config into effects_config from fauxlore.economy_parameters where singleton;
    corruption_steps:=fauxlore.corruption_step((indicators->>'total_development')::numeric,(indicators->>'development_limit')::numeric,(indicators->>'stability')::numeric,effects_config);
    next_corruption:=round(greatest(.02,least(.9,(indicators->>'corruption')::numeric+(corruption_steps->>'corruption_step_pp')::numeric/100)),7);

    with cfg as (
      select config from fauxlore.economy_parameters where singleton=true
    ),
    foods as (
      select r->>'name' name,(r->>'consumption')::numeric consumption
      from cfg cross join lateral jsonb_array_elements(cfg.config->'resources') r
      where r->>'name' in ('Зерно','Морепродукты','Животноводство','Фрукты')
        and coalesce((r->>'consumption')::numeric,0)>0
    ),
    owner_population as (
      select ov.category_id state_id,sum(greatest(p.population,0))::numeric population
      from fauxlore.provinces p
      join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
      where p.kind='land'
      group by ov.category_id
    ),
    consumption as (
      select op.state_id,f.name,ceil(op.population/10*f.consumption)::numeric(14,2) amount
      from owner_population op cross join foods f
    ),
    province_output as (
      select case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end state_id,
        resource.name resource_name,
        round(greatest(p.population,0)::numeric*(rc.r->>'production')::numeric*fauxlore.group_status_effect(case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end,'race',(select category_id from fauxlore.province_values where province_id=p.id and layer='races'),'production')*fauxlore.group_status_effect(case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'production')*
          (cfg.config#>>array['provinceModifiers',p.province_type,'production'])::numeric*
          coalesce(p.control,100)::numeric/100*greatest(0,coalesce(p.development,100))::numeric/100*(1-coalesce(owner_profile.crime,.2))*
          case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 1 end,0) amount
      from fauxlore.provinces p
      join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='resources'
      join fauxlore.map_categories resource on resource.layer='resources' and resource.id=rv.category_id
      left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
      left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
      left join fauxlore.map_categories occupier on lower(occupier.name)=lower(p.occupation) and occupier.layer='states'
      left join fauxlore.state_profiles owner_profile on owner_profile.state_id=owner.id
      cross join cfg cross join lateral jsonb_array_elements(cfg.config->'resources') rc(r)
      where p.kind='land' and resource.name=rc.r->>'name'
        and resource.name in ('Зерно','Морепродукты','Животноводство','Фрукты')
        and (case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end) is not null
    ),
    production as (
      select state_id,resource_name,sum(amount)::numeric(14,2) amount
      from province_output group by state_id,resource_name
    ),
    trade_delta as (
      select case when ts.direction='forward' then ta.from_state_id else ta.to_state_id end state_id,
        ts.item_name resource_name,-ts.sent amount
      from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id
      where ts.year=new.year and ts.turn=new.turn and ts.item_kind='resource'
      union all
      select case when ts.direction='forward' then ta.to_state_id else ta.from_state_id end,
        ts.item_name,ts.received
      from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id
      where ts.year=new.year and ts.turn=new.turn and ts.item_kind='resource'
      union all
      select buyer_state_id,resource_name,quantity from fauxlore.trade_market_settlements where year=new.year and turn=new.turn
      union all
      select seller_state_id,resource_name,-quantity from fauxlore.trade_market_settlements where year=new.year and turn=new.turn
      union all
      select buyer_state_id,resource_name,quantity from fauxlore.trade_interzone_settlements where year=new.year and turn=new.turn
      union all
      select seller_state_id,resource_name,-quantity from fauxlore.trade_interzone_settlements where year=new.year and turn=new.turn
    ),
    food_balances as (
      select sr.state_id,f.name,
        coalesce(prod.amount,0)-coalesce(cons.amount,0)+coalesce(delta.amount,0) balance,
        coalesce(cons.amount,0) required
      from (select state_row.state_id) sr cross join foods f
      left join production prod on prod.state_id=sr.state_id and prod.resource_name=f.name
      left join consumption cons on cons.state_id=sr.state_id and cons.name=f.name
      left join (select state_id,resource_name,sum(amount)::numeric(14,2) amount from trade_delta group by state_id,resource_name) delta
        on delta.state_id=sr.state_id and delta.resource_name=f.name
    )
    select coalesce(sum(required),0),coalesce(sum(greatest(0,-balance)),0)
      into required_units,deficit_units from food_balances;

    coverage_pct:=case when required_units<=0 then 100
      else greatest(0,least(100,round((1-deficit_units/required_units)*100,2))) end;
    steps:=fauxlore.crime_step(coverage_pct,(indicators->>'stability')::numeric);
    next_crime:=greatest(.02,least(1,state_crime+(steps->>'crime_step_pp')::numeric/100));
    state_item:=jsonb_build_object(
      'id',state_row.state_id,'name',state_row.name,
      'food_required_units',required_units,
      'food_deficit_units',deficit_units,
      'food_coverage_pct',coverage_pct,
      'crime_rate_at_turn_start_pct',round(state_crime*100,2),
      'indicators_at_turn_start',indicators,'stability_at_turn_start_pct',round((indicators->>'stability')::numeric*100,4),
      'food_step_pp',steps->'food_step_pp','stability_step_pp',steps->'stability_step_pp','crime_step_pp',steps->'crime_step_pp',
      'crime_rate_after_pct',round(next_crime*100,2),'crime_change_pp',round((next_crime-state_crime)*100,2),
      'corruption_rate_at_turn_start_pct',(indicators->>'corruption')::numeric*100,'corruption_rate_after_pct',next_corruption*100,
      'corruption_change_pp',round((next_corruption-(indicators->>'corruption')::numeric)*100,5),
      'corruption_overload_step_pp',corruption_steps->'corruption_overload_step_pp','corruption_stability_step_pp',corruption_steps->'corruption_stability_step_pp','corruption_step_pp',corruption_steps->'corruption_step_pp',
      'state_effect_coefficients',effects_config->'stateEffects','corruption_loyalty_bonus_at_start_pp',(indicators->>'corruption_loyalty_bonus')::numeric*100,
      'corruption_loyalty_bonus_next_pp',least((effects_config#>>'{stateEffects,corruptionLoyaltyCap}')::numeric,next_corruption/(effects_config#>>'{stateEffects,corruptionLoyaltyDivisor}')::numeric)*100
    );

    if exists(select 1 from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) x where x->>'id' ~ '^[0-9]+$' and (x->>'id')::integer=state_row.state_id) then
      select coalesce(jsonb_agg(case when x.value->>'id' ~ '^[0-9]+$' and (x.value->>'id')::integer=state_row.state_id then x.value||state_item else x.value end order by x.ord),'[]'::jsonb)
        into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality x(value,ord);
    else
      report_value:=coalesce(report_value,'[]'::jsonb)||jsonb_build_array(state_item);
    end if;
  end loop;

  update fauxlore.state_profiles sp set crime=(r->>'crime_rate_after_pct')::numeric/100,corruption=(r->>'corruption_rate_after_pct')::numeric/100
  from jsonb_array_elements(report_value) r where sp.state_id=(r->>'id')::integer;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb)
  where year=new.year and turn=new.turn;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION fauxlore.trade_zone_influence(state_value integer, zone_value integer)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with cfg as (select config from fauxlore.economy_parameters where singleton=true)
 select coalesce(sum((cfg.config#>>array['provinceModifiers',p.province_type,'tradeBase'])::numeric
 *(cfg.config#>>array['provinceModifiers',p.province_type,'trade'])::numeric
 *(cfg.config#>>array['tradeStatusModifiers',coalesce(p.trade_status,'Отсутствует')])::numeric
 *greatest(0,coalesce(p.development,100))::numeric/100
 *case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then
   case when occupier.id=state_value then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 0 end
  else case when owner.id=state_value then 1 else 0 end end),0)
 from fauxlore.provinces p
 join fauxlore.province_values zone on zone.province_id=p.id and zone.layer='trade' and zone.category_id=zone_value
 left join fauxlore.province_values owner_value on owner_value.province_id=p.id and owner_value.layer='states'
 left join fauxlore.map_categories owner on owner.layer='states' and owner.id=owner_value.category_id
 left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
 cross join cfg where p.kind='land'
$function$;
