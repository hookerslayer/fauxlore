-- Operator-only rollback for the three state-indicator migrations.
-- If state effects were deployed, run state_effects.sql first.
-- Use before any subsequent indicator migrations. Revert the client as well.
-- Development limits are lost when the column is dropped; export them first
-- if administrator edits must be retained. Historical reports remain readable.
begin;
do $$
declare fn text;
begin
  fn:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  execute replace(fn,'elsif path ~ ''^(my|admin)/states/[0-9]+/indicators$'' then return fauxlore.state_indicators_api(path,method,body,request_id);','');
  fn:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  execute replace(fn,'then fauxlore.state_population_growth(c.id)||jsonb_build_object(','then jsonb_build_object(');
end $$;
-- Report food coverage after direct trade contracts and all market flows settle.
-- This first stage is deliberately observational: it does not mutate crime,
-- population, or production parameters.

create or replace function fauxlore.report_food_security_after_turn()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  state_row record;
  report_value jsonb;
  state_item jsonb;
  required_units numeric(14,2);
  deficit_units numeric(14,2);
  coverage_pct numeric(7,2);
  state_crime numeric(5,4);
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
    state_item:=jsonb_build_object(
      'id',state_row.state_id,'name',state_row.name,
      'food_required_units',required_units,
      'food_deficit_units',deficit_units,
      'food_coverage_pct',coverage_pct,
      'crime_rate_at_turn_start_pct',round(state_crime*100,2)
    );

    if exists(select 1 from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) x where x->>'id' ~ '^[0-9]+$' and (x->>'id')::integer=state_row.state_id) then
      select coalesce(jsonb_agg(case when x.value->>'id' ~ '^[0-9]+$' and (x.value->>'id')::integer=state_row.state_id then x.value||state_item else x.value end order by x.ord),'[]'::jsonb)
        into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality x(value,ord);
    else
      report_value:=coalesce(report_value,'[]'::jsonb)||jsonb_build_array(state_item);
    end if;
  end loop;

  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb)
  where year=new.year and turn=new.turn;
  return new;
end $$;
revoke all on function fauxlore.report_food_security_after_turn() from public,anon,authenticated;

drop trigger if exists zzzz_report_food_security_after_turn on fauxlore.turn_economy_reports;
create trigger zzzz_report_food_security_after_turn
after insert on fauxlore.turn_economy_reports
for each row execute function fauxlore.report_food_security_after_turn();

notify pgrst,'reload schema';

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


drop function fauxlore.state_indicators_api(text,text,jsonb,uuid);
drop function fauxlore.state_indicators(integer);
drop function fauxlore.state_indicators_before_urbanization(integer);
drop function fauxlore.state_population_growth(integer);
drop function fauxlore.crime_step(numeric,numeric);
alter table fauxlore.state_profiles drop column development_limit;
notify pgrst,'reload schema';
commit;
