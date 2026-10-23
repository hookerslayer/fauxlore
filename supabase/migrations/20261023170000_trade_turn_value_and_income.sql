-- Target trade economy: value actual fulfilled demand once at each market stage.
-- The existing free resource allocator remains responsible for quantities.
create table if not exists fauxlore.trade_state_resource_turns(
  year integer not null, turn integer not null, state_id integer not null,
  resource_name text not null, production numeric(14,2) not null,
  consumption numeric(14,2) not null, contract_import numeric(14,2) not null,
  contract_export numeric(14,2) not null, zone_import numeric(14,2) not null,
  zone_export numeric(14,2) not null, base_price numeric(14,4) not null,
  dynamic_price numeric(14,4) not null, internal_quantity numeric(14,2) not null,
  turnover numeric(18,2) not null, duty_income numeric(18,2) not null,
  primary key(year,turn,state_id,resource_name)
);
create table if not exists fauxlore.trade_zone_resource_turns(
  year integer not null, turn integer not null, zone_id integer not null,
  resource_name text not null, demand numeric(14,2) not null,
  local_supply numeric(14,2) not null, incoming numeric(14,2) not null,
  local_quantity numeric(14,2) not null, exported numeric(14,2) not null,
  base_price numeric(14,4) not null, dynamic_price numeric(14,4) not null,
  local_turnover numeric(18,2) not null, incoming_turnover numeric(18,2) not null,
  primary key(year,turn,zone_id,resource_name)
);
create table if not exists fauxlore.trade_zone_income_turns(
  year integer not null, turn integer not null, zone_id integer not null,
  state_id integer not null, influence numeric(18,4) not null,
  local_income numeric(18,2) not null, export_income numeric(18,2) not null,
  primary key(year,turn,zone_id,state_id)
);
alter table fauxlore.trade_state_resource_turns enable row level security;
alter table fauxlore.trade_zone_resource_turns enable row level security;
alter table fauxlore.trade_zone_income_turns enable row level security;
revoke all on fauxlore.trade_state_resource_turns,fauxlore.trade_zone_resource_turns,fauxlore.trade_zone_income_turns from public,anon,authenticated;

-- The old trigger creates a levy only on local receipts at a fixed base price.
-- The new levy is charged once on fulfilled internal demand after all flows.
create or replace function fauxlore.apply_internal_trade_duty()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  new.internal_duty_amount:=0;
  return new;
end $$;

-- Preserve the position immediately after contracts, before local and remote allocation.
do $$
declare definition text; marker text := '  for market_row in';
begin
  definition:=pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure);
  if position('trade_open_position' in definition)=0 then
    if position(marker in definition)=0 then raise exception 'Trade market insertion point missing'; end if;
    execute replace(definition,marker,
      '  create temporary table if not exists pg_temp.trade_open_position (like pg_temp.trade_zone_position including all) on commit drop;'||chr(10)||
      '  truncate pg_temp.trade_open_position;'||chr(10)||
      '  insert into pg_temp.trade_open_position select * from pg_temp.trade_zone_position;'||chr(10)||marker);
  end if;
end $$;

create or replace function fauxlore.trade_dynamic_price(base_value numeric, elasticity numeric, demand numeric, supply numeric)
returns numeric language sql immutable set search_path='' as $$
 select round((base_value * greatest(.2,least(5,power(greatest(demand,0)/greatest(supply,.0001),elasticity))))::numeric,4)
$$;
revoke all on function fauxlore.trade_dynamic_price(numeric,numeric,numeric,numeric) from public,anon,authenticated;

create or replace function fauxlore.finish_trade_value_turn()
returns trigger language plpgsql security definer set search_path='' as $$
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
        coalesce(p.control,100)::numeric/100*(1-coalesce(owner_profile.crime,.2))*
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
end $$;
revoke all on function fauxlore.finish_trade_value_turn() from public,anon,authenticated;
drop trigger if exists zz_turn_economy_reports_trade_value on fauxlore.turn_economy_reports;
create trigger zz_turn_economy_reports_trade_value after insert on fauxlore.turn_economy_reports
for each row execute function fauxlore.finish_trade_value_turn();

create or replace function fauxlore.trade_overview_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; target_state integer; latest_year integer; latest_turn integer;
begin
  if path !~ '^(my|admin)/states/[0-9]+/trade-overview$' or method<>'GET' or body<>'{}'::jsonb
    then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  actor:=fauxlore.current_account();
  target_state:=split_part(path,'/',3)::integer;
  if split_part(path,'/',1)='admin' and actor.role<>'admin' then raise sqlstate '42501' using message='Доступ запрещён'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
    where account_id=actor.id and layer='states' and state_id=target_state)
    then raise sqlstate '42501' using message='Доступ запрещён'; end if;
  select year,turn into latest_year,latest_turn from fauxlore.trade_state_resource_turns
    order by year desc,turn desc limit 1;
  return jsonb_build_object('year',latest_year,'turn',latest_turn,
    'resources',coalesce((select jsonb_agg(to_jsonb(r) order by r.resource_name)
      from fauxlore.trade_state_resource_turns r where r.year=latest_year and r.turn=latest_turn and r.state_id=target_state),'[]'::jsonb),
    'zones',coalesce((select jsonb_agg(jsonb_build_object('id',z.id,'name',z.name,
      'resources',coalesce((select jsonb_agg(to_jsonb(r) order by r.resource_name)
        from fauxlore.trade_zone_resource_turns r where r.year=latest_year and r.turn=latest_turn and r.zone_id=z.id),'[]'::jsonb),
      'participants',coalesce((select jsonb_agg(to_jsonb(i)||jsonb_build_object('state_name',c.name) order by i.influence desc,i.state_id)
        from fauxlore.trade_zone_income_turns i join fauxlore.map_categories c on c.layer='states' and c.id=i.state_id
        where i.year=latest_year and i.turn=latest_turn and i.zone_id=z.id),'[]'::jsonb))
      order by z.id) from fauxlore.map_categories z where z.layer='trade'
      and exists(select 1 from fauxlore.provinces p join fauxlore.province_values zv on zv.province_id=p.id and zv.layer='trade'
        join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
        where p.kind='land' and zv.category_id=z.id and (ov.category_id=target_state
          or lower(p.occupation)=(select lower(name) from fauxlore.map_categories where layer='states' and id=target_state)))),'[]'::jsonb),
    'flows',coalesce((select jsonb_agg(to_jsonb(f)||jsonb_build_object('from_zone',origin.name,'to_zone',destination.name,
      'buyer',buyer.name,'seller',seller.name) order by f.from_zone_id,f.to_zone_id,f.resource_name,f.id)
      from fauxlore.trade_interzone_settlements f
      join fauxlore.map_categories origin on origin.layer='trade' and origin.id=f.from_zone_id
      join fauxlore.map_categories destination on destination.layer='trade' and destination.id=f.to_zone_id
      join fauxlore.map_categories buyer on buyer.layer='states' and buyer.id=f.buyer_state_id
      join fauxlore.map_categories seller on seller.layer='states' and seller.id=f.seller_state_id
      where f.year=latest_year and f.turn=latest_turn
        and (f.from_zone_id in (select zone_id from fauxlore.trade_zone_income_turns
          where year=latest_year and turn=latest_turn and state_id=target_state)
          or f.buyer_state_id=target_state or f.seller_state_id=target_state)),'[]'::jsonb));
end $$;
revoke all on function fauxlore.trade_overview_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.trade_overview_api(text,text,jsonb,uuid) to authenticated;
do $$
declare definition text; marker text := 'elsif path=''admin/turn/test'' or path like ''admin/turn/test/%'' then';
begin
  definition:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  if position('trade_overview_api' in definition)=0 then
    if position(marker in definition)=0 then raise exception 'Trade overview API insertion point missing'; end if;
    execute replace(definition,marker,
      'elsif path ~ ''^(my|admin)/states/[0-9]+/trade-overview$'' then return fauxlore.trade_overview_api(path,method,body,request_id);'||chr(10)||'  '||marker);
  end if;
end $$;

-- Test-turn rollback must restore the new journals along with treasuries.
do $$
declare definition text; table_name text; marker text; at_pos integer;
begin
  foreach table_name in array array['trade_state_resource_turns','trade_zone_resource_turns','trade_zone_income_turns'] loop
    definition:=pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure);
    if position(quote_literal(table_name) in definition)=0 then
      marker:='''turn_economy_reports'',';
      if position(marker in definition)=0 then raise exception 'Snapshot insertion point missing'; end if;
      execute replace(definition,marker,
        quote_literal(table_name)||',(select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from fauxlore.'||table_name||' x),'||marker);
    end if;
    definition:=pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure);
    if position('delete from fauxlore.'||table_name in definition)=0 then
      marker:='''turn_economy_reports'',';
      at_pos:=position(marker in definition);
      if at_pos=0 then raise exception 'Test snapshot insertion point missing'; end if;
      definition:=substr(definition,1,at_pos-1)||
        quote_literal(table_name)||',(select coalesce(jsonb_agg(to_jsonb(x)),''[]''::jsonb) from fauxlore.'||table_name||' x),'||
        substr(definition,at_pos);
      marker:='delete from fauxlore.turn_economy_reports where true;';
      if position(marker in definition)=0 then raise exception 'Test rollback cleanup insertion point missing'; end if;
      definition:=replace(definition,marker,'delete from fauxlore.'||table_name||' where true; '||marker);
      marker:='''turn_economy_reports'',''game_calendar''';
      if position(marker in definition)>0 then
        definition:=replace(definition,marker,quote_literal(table_name)||','||marker);
      end if;
      execute definition;
    end if;
  end loop;
end $$;
notify pgrst,'reload schema';
