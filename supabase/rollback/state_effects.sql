-- Operator-only rollback of approved corruption/crime effects.
-- Revert the client to its pre-effects version in the same release.
-- Export corruption values first if sub-0.01 pp precision must be preserved.
-- Leaves the independent config-dispatch bug fix in place.
begin;
CREATE OR REPLACE FUNCTION fauxlore.turn_api(path text, method text, body jsonb, request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a fauxlore.accounts; calendar_row fauxlore.game_calendar; previous fauxlore.operations;
  fingerprint text; result jsonb; cfg jsonb; tax_rows jsonb; state_rows jsonb; states_count integer:=0;
  province_row record; tax_gross numeric; crown_tax numeric; estate_tax numeric; status_value text;
  beneficiary_id integer; beneficiary_name text; tax_share numeric; expected_year integer; expected_turn integer; race_rate numeric; religion_rate numeric;
  report_value jsonb:='[]'::jsonb;
begin
  if path='game/calendar' and method='GET' then
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    return jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn);
  end if;
  if path<>'admin/turn/advance' or method<>'POST' or jsonb_typeof(body) is distinct from 'object' or
    body-array['expected_year','expected_turn','report']<>'{}' or
    jsonb_typeof(body->'expected_year') is distinct from 'number' or jsonb_typeof(body->'expected_turn') is distinct from 'number' then
    raise sqlstate '22023' using message='Некорректный запрос смены хода';
  end if;
  if (body->>'expected_year')!~'^\d+$' or (body->>'expected_turn')!~'^\d+$' then
    raise sqlstate '22023' using message='Ожидаемые год и ход должны быть целыми числами';
  end if;
  if body ? 'report' and (jsonb_typeof(body->'report') is distinct from 'array' or octet_length((body->'report')::text)>1500000) then
    raise sqlstate '22023' using message='Некорректный запрос смены хода';
  end if;
  expected_year:=(body->>'expected_year')::integer; expected_turn:=(body->>'expected_turn')::integer;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=turn_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true for update;
  if calendar_row.year<>expected_year or calendar_row.turn<>expected_turn then
    raise sqlstate '40001' using message='Ход уже изменён в другой сессии. Обновите страницу и повторите.';
  end if;
  select config into cfg from fauxlore.economy_parameters where singleton=true for share;

  create temporary table if not exists pg_temp.turn_tax_lines(
    province_id integer, province_name text, recipient_id integer, recipient_name text,
    belonging text, gross numeric, crown numeric, estate numeric
  ) on commit drop;
  truncate pg_temp.turn_tax_lines;
  for province_row in
    select p.id,p.name,p.population,p.province_type,p.control,p.occupation,
      race.name race_name,rv.category_id race_id,religion.name religion_name,relv.category_id religion_id,owner.id owner_id,owner.name owner_name,
      occupier.id occupier_id,occupier.name occupier_name,
      p.belonging
    from fauxlore.provinces p
    left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
    left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id
    left join fauxlore.province_values relv on relv.province_id=p.id and relv.layer='religions'
    left join fauxlore.map_categories religion on religion.layer='religions' and religion.id=relv.category_id
    left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    where p.kind='land' and (ov.category_id is not null or p.occupation is not null)
    order by p.id
  loop
    if province_row.occupation is not null and (province_row.owner_id is null or lower(province_row.occupation)<>lower(province_row.owner_name)) then
      beneficiary_id:=province_row.occupier_id; beneficiary_name:=province_row.occupier_name; tax_share:=.5;
      if beneficiary_id is null then raise sqlstate '22023' using message='Не найдено государство-оккупант провинции '||province_row.id; end if;
    else
      beneficiary_id:=province_row.owner_id; beneficiary_name:=province_row.owner_name; tax_share:=1;
    end if;
    if beneficiary_id is null then continue; end if;
    if province_row.race_name is null or province_row.religion_name is null then
      raise sqlstate '22023' using message='Для провинции '||province_row.id||' не заданы раса или религия'; end if;
    race_rate:=fauxlore.effective_state_tax_rate(beneficiary_id,'races',province_row.race_id,cfg);
    religion_rate:=fauxlore.effective_state_tax_rate(beneficiary_id,'religions',province_row.religion_id,cfg);
    if nullif(cfg#>>array['provinceModifiers',province_row.province_type,'tax'],'') is null or race_rate is null or religion_rate is null then
      raise sqlstate '22023' using message='Не заданы налоговые коэффициенты провинции '||province_row.id; end if;
    if coalesce(province_row.control,100)<0 or coalesce(province_row.control,100)>100 then
      raise sqlstate '22023' using message='Контроль провинции должен быть от 0 до 100'; end if;
    tax_gross:=round(greatest(0,province_row.population)::numeric/10 *
      (race_rate+religion_rate) *
      (cfg#>>array['provinceModifiers',province_row.province_type,'tax'])::numeric *
      coalesce(province_row.control,100)::numeric/100 * tax_share,2);
    beneficiary_id:=case when province_row.occupation is not null and tax_share=.5 then province_row.occupier_id else province_row.owner_id end;
    if beneficiary_id is null then continue; end if;
    if province_row.belonging is null or province_row.belonging='Отсутствует' then
      select crown,estate into crown_tax,estate_tax from fauxlore.split_province_tax(tax_gross,'Отсутствует',null,cfg);
    else
      status_value:=fauxlore.estate_status_for(beneficiary_id,province_row.belonging);
      select crown,estate into crown_tax,estate_tax from fauxlore.split_province_tax(tax_gross,province_row.belonging,status_value,cfg);
    end if;
    insert into pg_temp.turn_tax_lines values(province_row.id,province_row.name,beneficiary_id,beneficiary_name,
      coalesce(province_row.belonging,'Отсутствует'),tax_gross,crown_tax,estate_tax);
  end loop;

  with receipts as (
    select recipient_id,'Корона'::text estate,sum(crown)::numeric(14,2) amount from pg_temp.turn_tax_lines group by recipient_id
    union all
    select recipient_id,belonging,sum(estate)::numeric(14,2) from pg_temp.turn_tax_lines where belonging<>'Отсутствует' group by recipient_id,belonging
  )
  insert into fauxlore.state_treasuries(state_id,estate,balance)
  select recipient_id,estate,amount from receipts where amount<>0
  on conflict(state_id,estate) do update set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
  update fauxlore.state_profiles sp set treasury=(select coalesce(sum(st.balance),0) from fauxlore.state_treasuries st where st.state_id=sp.state_id)
  where exists(select 1 from pg_temp.turn_tax_lines l where l.recipient_id=sp.state_id);

  select coalesce(jsonb_agg(state_report order by state_report->>'name'),'[]'::jsonb),count(*)::integer
    into report_value,states_count
  from (
    select jsonb_build_object(
      'id',s.recipient_id,'name',s.recipient_name,
      'province_count',count(distinct l.province_id),
      'gross_taxes',round(coalesce(sum(l.gross),0),2),
      'crown_taxes',round(coalesce(sum(l.crown),0),2),
      'estate_taxes',round(coalesce(sum(l.estate),0),2),
      'tax_buckets',coalesce((select jsonb_object_agg(st.estate,round(st.balance,2)) from fauxlore.state_treasuries st where st.state_id=s.recipient_id),'{}'::jsonb),
      'opening_treasury',round(coalesce((select sum(st.balance) from fauxlore.state_treasuries st where st.state_id=s.recipient_id),0)-coalesce(sum(l.crown+l.estate),0),2),
      'closing_treasury',round(coalesce((select sum(st.balance) from fauxlore.state_treasuries st where st.state_id=s.recipient_id),0),2),
      'tax_details',coalesce(jsonb_agg(jsonb_build_object('province_id',l.province_id,'province_name',l.province_name,
        'belonging',l.belonging,'gross',l.gross,'crown',l.crown,'estate',l.estate) order by l.province_id)
        filter(where l.province_id is not null),'[]'::jsonb)
    ) state_report
    from (select distinct recipient_id,recipient_name from pg_temp.turn_tax_lines) s
    left join pg_temp.turn_tax_lines l on l.recipient_id=s.recipient_id
    group by s.recipient_id,s.recipient_name
  ) reports;
  insert into fauxlore.turn_economy_reports(year,turn,report,created_by)
    values(calendar_row.year,calendar_row.turn,report_value,a.id);

  -- Keep the established annual character lifecycle within this same atomic turn.
  for province_row in
    select ch.id,ch.state_id,ch.age,ch.name,ch.surname,ch.is_current_ruler,coalesce(rc.name,'') race_name
    from fauxlore.state_characters ch left join fauxlore.map_categories rc on rc.layer='races' and rc.id=ch.race_id
    where ch.alive order by ch.id for update of ch
  loop
    declare age_value integer; death_chance numeric; died boolean;
    begin
      age_value:=least(250,province_row.age+1);
      death_chance:=case
        when province_row.race_name in ('Люди','Полуэльфы','Зверолюди') then case when age_value<60 then 0 when age_value<=70 then .05 when age_value<=80 then .15 when age_value<=90 then .25 when age_value<=100 then .50 else .70 end
        when province_row.race_name='Дварфы' then case when age_value<80 then 0 when age_value<=90 then .05 when age_value<=100 then .15 when age_value<=110 then .25 when age_value<=120 then .50 else .70 end
        when province_row.race_name='Эльфы' then case when age_value<100 then 0 when age_value<=120 then .05 when age_value<=140 then .15 when age_value<=160 then .25 when age_value<=180 then .50 else .70 end
        else 0 end;
      died:=death_chance>0 and random()<death_chance;
      update fauxlore.state_characters set age=age_value,alive=not died,
        died_at_turn=case when died then calendar_row.turn else died_at_turn end,
        is_current_ruler=case when died and province_row.is_current_ruler then false else is_current_ruler end where id=province_row.id;
      if died and province_row.is_current_ruler then
        insert into fauxlore.notifications(account_id,kind,title,message)
        select recipients.account_id,'ruler_death','Умер правитель государства',
          'Правитель '||trim(province_row.name||' '||province_row.surname)||' умер в возрасте '||age_value||' лет. Требуется провести передачу власти.'
        from (
          select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=province_row.state_id
          union
          select ac.id from fauxlore.accounts ac where ac.role='admin'
            and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=province_row.state_id)
        ) recipients;
      end if;
    end;
  end loop;
  update fauxlore.game_calendar set year=year+1,turn=turn+1,updated_at=now() where singleton=true returning * into calendar_row;
  result:=jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn,
    'calculated_year',calendar_row.year-1,'calculated_turn',calendar_row.turn-1,'states_calculated',states_count);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,turn_api.request_id,fingerprint,result);
  return result;
end $function$

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
  state_crime numeric(5,4); indicators jsonb; steps jsonb; next_crime numeric;
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
        round(greatest(p.population,0)::numeric*(rc.r->>'production')::numeric*
          (cfg.config#>>array['provinceModifiers',p.province_type,'production'])::numeric*
          coalesce(p.control,100)::numeric/100*(1-coalesce(owner_profile.crime,.2))*
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
      'crime_rate_after_pct',round(next_crime*100,2),'crime_change_pp',round((next_crime-state_crime)*100,2)
    );

    if exists(select 1 from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) x where x->>'id' ~ '^[0-9]+$' and (x->>'id')::integer=state_row.state_id) then
      select coalesce(jsonb_agg(case when x.value->>'id' ~ '^[0-9]+$' and (x.value->>'id')::integer=state_row.state_id then x.value||state_item else x.value end order by x.ord),'[]'::jsonb)
        into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality x(value,ord);
    else
      report_value:=coalesce(report_value,'[]'::jsonb)||jsonb_build_array(state_item);
    end if;
  end loop;

  update fauxlore.state_profiles sp set crime=(r->>'crime_rate_after_pct')::numeric/100
  from jsonb_array_elements(report_value) r where sp.state_id=(r->>'id')::integer;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb)
  where year=new.year and turn=new.turn;
  return new;
end $function$

CREATE OR REPLACE FUNCTION fauxlore.map_payload()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
with s as (select (select jsonb_object_agg(key,value_json) from fauxlore._settings)||jsonb_build_object('economy_config',fauxlore.economy_config_payload()) as data),
visible as (select p.* from fauxlore.provinces p cross join s where
  (p.bbox->>0)::numeric<(s.data->'region'->>2)::numeric and (p.bbox->>2)::numeric>(s.data->'region'->>0)::numeric and
  (p.bbox->>1)::numeric<(s.data->'region'->>3)::numeric and (p.bbox->>3)::numeric>(s.data->'region'->>1)::numeric),
layers as (select v.province_id,jsonb_object_agg(v.layer,jsonb_build_object('id',c.id,'name',c.name,'color',c.color)||
  case when v.layer='states' then fauxlore.state_population_growth(c.id)||jsonb_build_object('crime',coalesce((select sp.crime from fauxlore.state_profiles sp where sp.state_id=c.id),0.2),'race_tax_rates',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer='races'),'{}'::jsonb),'religion_tax_rates',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer='religions'),'{}'::jsonb)) else '{}'::jsonb end) data
  from fauxlore.province_values v join visible p on p.id=v.province_id join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id group by v.province_id)
select s.data||jsonb_build_object('provinces',coalesce((select jsonb_agg(case when p.kind='sea' then to_jsonb(p)-array['province_type','population','development','taxes','production','warehouse','control','occupation','tension','has_capital_marker','has_city_marker']
  else to_jsonb(p)||jsonb_build_object('layers',coalesce(l.data,'{}'),'occupation_color',c.color,'occupation_race_tax_rates',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer='races'),'{}'::jsonb),'occupation_religion_tax_rates',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer='religions'),'{}'::jsonb)) end||jsonb_build_object('application_pending',exists(select 1 from fauxlore.application_provinces ap where ap.province_id=p.id)) order by p.id)
  from visible p left join layers l on l.province_id=p.id left join fauxlore.map_categories c on c.layer='states' and lower(c.name)=lower(p.occupation)),'[]'),
  'pending_application_provinces',coalesce((select jsonb_agg(ap.province_id order by ap.province_id) from fauxlore.application_provinces ap),'[]'::jsonb),
  'roads',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'type',r.type,'anchors',r.anchors,'segments',r.segments) order by r.id) from fauxlore.map_roads r where exists(select 1 from jsonb_array_elements(r.anchors) anchor join visible p on p.id=(anchor->>'province_id')::integer)),'[]'),
  'categories',coalesce((select jsonb_agg(to_jsonb(c)||case when c.layer='states' then jsonb_build_object('crime',coalesce(sp.crime,0.2)) else '{}'::jsonb end order by c.layer,c.id) from fauxlore.map_categories c left join fauxlore.state_profiles sp on sp.state_id=c.id and c.layer='states'),'[]'),
  'markers',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('state_name',c.name) order by m.id) from fauxlore.map_markers m join visible p on p.id=m.province_id left join fauxlore.map_categories c on c.layer=m.state_layer and c.id=m.state_id),'[]')) from s
$function$

CREATE OR REPLACE FUNCTION fauxlore.state_population_growth(target_state integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with owned as (select p.*,race.name race from fauxlore.provinces p
join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=target_state
left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id where p.kind='land'),
urban as (select coalesce(sum(population*case province_type when 'Столичная' then .35 when 'Городская' then .2 else 0 end)/nullif(sum(population),0),0) ratio from owned),
modifier as (select greatest(.5,1-greatest(0,ratio-.15)*.5) value from urban),
growth as (select case when count(*) filter(where cfg.config#>>array['raceGrowthModifiers',p.race] is null)>0 then null
else coalesce(sum(round(p.population*.03*(cfg.config#>>array['raceGrowthModifiers',p.race])::numeric*m.value,0)),0) end value
from owned p cross join modifier m cross join fauxlore.economy_parameters cfg where cfg.singleton)
select jsonb_build_object('urbanization_growth_multiplier',m.value,'population_growth',g.value) from modifier m cross join growth g
$function$

create or replace function fauxlore.province_value_for_state(target_province integer,target_state integer)
returns numeric language plpgsql stable security definer set search_path='' as $$
declare p fauxlore.provinces; cfg jsonb; state_name text; owner_state integer;
  race_name text; religion_name text; resource_name text; tax_mod numeric; prod_mod numeric;
  trade_mod numeric; trade_base numeric; trade_status_mod numeric; race_rate numeric; religion_rate numeric;
  resource_value numeric:=0; resource_prod numeric:=0; crime_rate numeric:=.2;
  share numeric:=0; control_value numeric; population numeric; tax_value numeric; production_value numeric;
  trade_value numeric; recruit_limit numeric; weights jsonb;
begin
  select * into p from fauxlore.provinces where id=target_province and kind='land';
  if not found then return null; end if;
  select config into cfg from fauxlore.economy_parameters where singleton=true;
  select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=target_state;
  select category_id into owner_state from fauxlore.province_values where province_id=p.id and layer='states';
  select c.name into race_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='races';
  select c.name into religion_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='religions';
  select c.name into resource_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='resources';
  if race_name is null or religion_name is null or state_name is null then return null; end if;
  if p.occupation is not null and (owner_state is null or lower(p.occupation)<>lower((select name from fauxlore.map_categories where layer='states' and id=owner_state))) then
    if lower(p.occupation)=lower(state_name) then share:=coalesce((cfg->>'occupationMultiplier')::numeric,.5); end if;
  elsif owner_state=target_state then share:=1;
  end if;
  if share=0 then return 0; end if;
  tax_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'tax'],'')::numeric;
  prod_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'production'],'')::numeric;
  trade_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'trade'],'')::numeric;
  trade_base:=nullif(cfg#>>array['provinceModifiers',p.province_type,'tradeBase'],'')::numeric;
  race_rate:=nullif(cfg#>>array['raceTaxRates',race_name],'')::numeric;
  religion_rate:=nullif(cfg#>>array['religionTaxRates',religion_name],'')::numeric;
  trade_status_mod:=nullif(cfg#>>array['tradeStatusModifiers',coalesce(p.trade_status,'Отсутствует')],'')::numeric;
  if tax_mod is null or prod_mod is null or trade_mod is null or trade_base is null or race_rate is null or religion_rate is null or trade_status_mod is null then return null; end if;
  select coalesce((r->>'value')::numeric,0),coalesce((r->>'production')::numeric,0) into resource_value,resource_prod
    from jsonb_array_elements(cfg->'resources') r where r->>'name'=resource_name limit 1;
  select coalesce(crime,.2) into crime_rate from fauxlore.state_profiles where state_id=target_state;
  crime_rate:=coalesce(crime_rate,.2); population:=greatest(0,p.population)::numeric;
  control_value:=coalesce(p.control,100)::numeric/100;
  tax_value:=round(population/10*(race_rate+religion_rate)*tax_mod*control_value*share,2);
  production_value:=round(population*resource_prod*prod_mod*control_value*(1-crime_rate)*share,0);
  trade_value:=round(trade_base*trade_mod*trade_status_mod*share,2);
  recruit_limit:=round(population/100
    *coalesce((cfg#>>array['recruitLimitModifiers',p.province_type])::numeric,0)
    *case when p.belonging='Отсутствует' then 0 else coalesce((cfg#>>array['estateRecruitModifiers',p.belonging])::numeric,0) end
    *control_value*share,0);
  weights:=cfg->'provinceValueWeights';
  return round(((tax_value+production_value*resource_value)*coalesce((weights->>'gold')::numeric,0))
    +(trade_value*coalesce((weights->>'trade')::numeric,0))
    +(production_value*resource_value*coalesce((weights->>'production')::numeric,0))
    +(recruit_limit*coalesce((weights->>'recruits')::numeric,0))
    +(population*coalesce((weights->>'population')::numeric,0)*share),0);
end $$;
revoke all on function fauxlore.province_value_for_state(integer,integer) from public,anon,authenticated;


do $$
declare fn text;
begin
  fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
  fn:=replace(fn,'race_rate:=nullif(cfg#>>array[''raceTaxRates'',race_name],'''')::numeric;',
    'race_rate:=fauxlore.effective_state_tax_rate(target_state,''races'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''races''),cfg);');
  fn:=replace(fn,'religion_rate:=nullif(cfg#>>array[''religionTaxRates'',religion_name],'''')::numeric;',
    'religion_rate:=fauxlore.effective_state_tax_rate(target_state,''religions'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),cfg);');
  fn:=replace(fn,'from fauxlore.state_profiles where state_id=target_state;', 'from fauxlore.state_profiles where state_id=owner_state;');
  execute fn;
end $$;


create or replace function fauxlore.state_indicators_before_urbanization(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with cfg as (select config from fauxlore.economy_parameters where singleton),
owned as (
  select p.* from fauxlore.provinces p join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
  where p.kind='land' and v.category_id=target_state
), aggregates as (
  select count(*) province_count,coalesce(sum(population),0) population,
    coalesce(sum(population*case province_type when 'Столичная' then .35 when 'Городская' then .2 else 0 end),0) urban,
    sum(development) development,count(*) filter(where development is null) missing_development
  from owned
), relevant as (
  select p.*,case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,''))
    then case when lower(p.occupation)=lower(target.name) then .5 else 0 end
    else case when ov.category_id=target_state then 1 else 0 end end share,
    rv.category_id race_id,rel.category_id religion_id
  from fauxlore.provinces p
  left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
  left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
  join fauxlore.map_categories target on target.layer='states' and target.id=target_state
  left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
  left join fauxlore.province_values rel on rel.province_id=p.id and rel.layer='religions'
  where p.kind='land' and (ov.category_id=target_state or lower(p.occupation)=lower(target.name))
), estates as (
  select e.name,coalesce(g.status,fauxlore.estate_status_for(target_state,e.name)) status,coalesce(g.loyalty,.5) loyalty,
    coalesce(sum(fauxlore.province_value_for_state(p.id,target_state)) filter(where p.share>0),0) weight,
    coalesce(sum(p.population*p.share*(fauxlore.effective_state_tax_rate(target_state,'races',p.race_id,cfg.config)
      +fauxlore.effective_state_tax_rate(target_state,'religions',p.religion_id,cfg.config))) filter(where p.share>0),0) actual,
    coalesce(sum(p.population*p.share*.2) filter(where p.share>0 and fauxlore.effective_state_tax_rate(target_state,'races',p.race_id,cfg.config) is not null
      and fauxlore.effective_state_tax_rate(target_state,'religions',p.religion_id,cfg.config) is not null),0) baseline
  from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) e(name) cross join cfg
  left join relevant p on p.belonging=e.name
  left join fauxlore.state_group_politics g on g.state_id=target_state and g.group_type='estate' and g.group_key=e.name
  group by e.name,g.status,g.loyalty
), influences as (
  select *,coalesce(weight/nullif(sum(weight) over(),0),0) influence from estates
), loyalties as (
  select *,greatest(0,least(1,loyalty+influence-case status when 'Ключевое' then .5 when 'Значимое' then .35 else 0 end
    -(case when baseline>0 then actual/baseline else 1 end-1)*coalesce((cfg.config->>'taxLoyaltySensitivity')::numeric,.5))) effective_loyalty
  from influences cross join cfg
), estate_block as (
  select greatest(0,least(1,.5+sum(influence*(effective_loyalty-.6)*2*
    case status when 'Ключевое' then 1.5 when 'Значимое' then 1 when 'Бесправное' then .25 else 0 end))) value from loyalties
), groups as (
  select v.layer,v.category_id,sum(p.population)::numeric population from owned p
  join fauxlore.province_values v on v.province_id=p.id and v.layer in ('races','religions') group by v.layer,v.category_id
), group_blocks as (
  select l.layer,greatest(0,least(1,case l.layer when 'religions' then .2 else 0 end+
    coalesce(sum(g.population/nullif(t.population,0)*(coalesce(gp.loyalty,.5)-.5)*2),0))) value
  from (values('races'),('religions')) l(layer)
  left join groups g on g.layer=l.layer
  left join (select layer,sum(population) population from groups group by layer) t on t.layer=l.layer
  left join fauxlore.state_group_politics gp on gp.state_id=target_state and gp.group_key=g.category_id::text
    and gp.group_type=case l.layer when 'races' then 'race' else 'religion' end
  group by l.layer
)
select jsonb_build_object('state_id',target_state,'population',a.population,'urban_population',a.urban,
  'rural_population',a.population-a.urban,'urbanization',coalesce(a.urban/nullif(a.population,0),0),
  'province_count',a.province_count,'total_development',case when a.province_count=0 then 0 else a.development end,
  'missing_development_count',a.missing_development,'development_limit',sp.development_limit,
  'overload',greatest(0,coalesce(a.development,0)-sp.development_limit),
  'overload_ratio',case when sp.development_limit>0 then greatest(0,coalesce(a.development,0)-sp.development_limit)::numeric/sp.development_limit else null end,
  'stability',(eb.value+(select sum(value) from group_blocks))/3,
  'stability_blocks',jsonb_build_object('estate',eb.value,'race',(select value from group_blocks where layer='races'),'religion',(select value from group_blocks where layer='religions')),
  'crime',sp.crime,'corruption',sp.corruption)
from aggregates a cross join estate_block eb join fauxlore.state_profiles sp on sp.state_id=target_state
$$;
revoke all on function fauxlore.state_indicators_before_urbanization(integer) from public,anon,authenticated;


create or replace function fauxlore.state_indicators(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
select fauxlore.state_indicators_before_urbanization(target_state)||fauxlore.state_population_growth(target_state)
$$;
do $undo$
declare fn text;
begin
fn:=pg_get_functiondef('fauxlore.economy_config_api(text,text,jsonb,uuid)'::regprocedure);
execute replace(fn,$remove$
  if jsonb_typeof(next_config->'stateEffects') is distinct from 'object' then raise sqlstate '22023' using message='Нужны коэффициенты состояния'; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(next_config->'stateEffects') k) is distinct from
    (select array_agg(k order by k) from jsonb_object_keys(old_config->'stateEffects') k) then raise sqlstate '22023' using message='Изменён состав коэффициентов состояния'; end if;
  for pair in select key,value from jsonb_each(next_config->'stateEffects') loop
    if jsonb_typeof(pair.value) is distinct from 'number' then raise sqlstate '22023' using message='Коэффициент состояния должен быть числом'; end if;
    if (pair.value#>>'{}')::numeric<0 or (pair.value#>>'{}')::numeric>100 or
      (pair.key in ('crimeTaxPenalty','crimePopulationPenalty','corruptionTaxPenalty','corruptionLoyaltyCap','urbanizationThreshold','urbanizationPenaltyCap') and (pair.value#>>'{}')::numeric>1) or
      (pair.key='corruptionLoyaltyDivisor' and (pair.value#>>'{}')::numeric<.001) then raise sqlstate '22023' using message='Коэффициент состояния вне допустимого диапазона'; end if;
  end loop;
$remove$,'');
end $undo$;
drop function fauxlore.state_recruitment(integer);
drop function fauxlore.corruption_step(numeric,numeric,numeric,jsonb);
drop function fauxlore.state_tax_breakdown(numeric,numeric,numeric,jsonb);
update fauxlore.economy_parameters set config=config-'stateEffects' where singleton;
alter table fauxlore.state_profiles alter column corruption type numeric(5,4);
notify pgrst,'reload schema';
commit;
