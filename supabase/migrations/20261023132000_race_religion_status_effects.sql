create or replace function fauxlore.group_status_loyalty_modifier(state_key integer,group_kind text,category_key integer)
returns numeric language sql stable security definer set search_path='' as $$
select case coalesce((select gp.status from fauxlore.state_group_politics gp where gp.state_id=state_key
  and gp.group_type=group_kind and gp.group_key=category_key::text),
  case when group_kind='race' and sp.official_race_id=category_key or group_kind='religion' and sp.official_religion_id=category_key then 'Официальная' else 'Невмешательство' end)
  when 'Официальная' then .10 when 'Невмешательство' then .05 when 'Ассимиляция' then -.10 when 'Истребление' then -.25 else 0 end
from fauxlore.state_profiles sp where sp.state_id=state_key
$$;
revoke all on function fauxlore.group_status_loyalty_modifier(integer,text,integer) from public,anon,authenticated;

create or replace function fauxlore.group_status_effect(state_key integer,group_kind text,category_key integer,metric text)
returns numeric language sql stable security definer set search_path='' as $$
select case coalesce((select gp.status from fauxlore.state_group_politics gp where gp.state_id=state_key
  and gp.group_type=group_kind and gp.group_key=category_key::text),
  case when group_kind='race' and sp.official_race_id=category_key or group_kind='religion' and sp.official_religion_id=category_key then 'Официальная' else 'Невмешательство' end)
  when 'Официальная' then case metric when 'population' then 1.1 else 1 end
  when 'Ассимиляция' then case metric when 'population' then .5 when 'tax' then .8 when 'production' then .7 when 'recruit' then 0 else 1 end
  when 'Истребление' then case metric when 'population' then 0 when 'tax' then .5 when 'production' then .5 when 'recruit' then 0 else 1 end
  else 1 end
from fauxlore.state_profiles sp where sp.state_id=state_key
$$;
revoke all on function fauxlore.group_status_effect(integer,text,integer,text) from public,anon,authenticated;

create or replace function fauxlore.effective_state_tax_rate(state_key integer,layer_key text,category_key integer,fallback_config jsonb)
returns numeric language sql stable security definer set search_path='' as $$
select coalesce(
  (select r.rate from fauxlore.state_tax_rates r where r.state_id=state_key and r.layer=layer_key and r.category_id=category_key),
  nullif(fallback_config#>>array[case layer_key when 'races' then 'raceTaxRates' else 'religionTaxRates' end,
    (select c.name from fauxlore.map_categories c where c.layer=layer_key and c.id=category_key)],'')::numeric
)*fauxlore.group_status_effect(state_key,case layer_key when 'races' then 'race' else 'religion' end,category_key,'tax')
$$;
revoke all on function fauxlore.effective_state_tax_rate(integer,text,integer,jsonb) from public,anon,authenticated;

-- Apply status loyalty to the same effective-loyalty input used by stability.
do $$
declare fn text; marker text:='(coalesce(gp.loyalty,.5)-.5)*2';
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Group stability marker missing'; end if;
  fn:=replace(fn,marker,'(greatest(0,least(1,coalesce(gp.loyalty,.5)+fauxlore.group_status_loyalty_modifier(target_state,'||
    'case l.layer when ''races'' then ''race'' else ''religion'' end,g.category_id)))-.5)*2');
  execute fn;
end $$;

-- Apply population status multipliers before each province is rounded.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.state_population_growth(integer)'::regprocedure);
  marker:='select p.*,race.name race from fauxlore.provinces p';
  if position(marker in fn)=0 then raise exception 'Population category key marker missing'; end if;
  fn:=replace(fn,marker,'select p.*,race.name race,rv.category_id race_id from fauxlore.provinces p');
  marker:='left join fauxlore.map_categories race on race.layer=''races'' and race.id=rv.category_id where p.kind=''land''';
  if position(marker in fn)=0 then raise exception 'Population growth category marker missing'; end if;
  fn:=replace(fn,marker,'left join fauxlore.map_categories race on race.layer=''races'' and race.id=rv.category_id'||
    ' left join fauxlore.province_values relv on relv.province_id=p.id and relv.layer=''religions'' where p.kind=''land''');
  marker:='m.urban*m.crime,0)),0) end value';
  if position(marker in fn)=0 then raise exception 'Population growth formula marker missing'; end if;
  fn:=replace(fn,'p.population*.03*(cfg.config#>>array[''raceGrowthModifiers'',p.race])::numeric*m.urban*m.crime,0)',
    'p.population*.03*(cfg.config#>>array[''raceGrowthModifiers'',p.race])::numeric*m.urban*m.crime*'||
    'fauxlore.group_status_effect(target_state,''race'',p.race_id,''population'')*'||
    'fauxlore.group_status_effect(target_state,''religion'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),''population''),0)');
  execute fn;
end $$;

-- Apply status multipliers to recruit growth and the derived recruitment limit.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.state_recruitment(integer)'::regprocedure);
  marker:='select p.*,case when p.occupation';
  if position(marker in fn)=0 then raise exception 'Recruitment province marker missing'; end if;
  fn:=replace(fn,marker,'select p.*,rv.category_id race_id,case when p.occupation');
  marker:='left join fauxlore.map_categories owner on owner.layer=''states'' and owner.id=ov.category_id';
  if position(marker in fn)=0 then raise exception 'Recruitment joins marker missing'; end if;
  fn:=replace(fn,marker,marker||' left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer=''races''');
  marker:='p.control/100*p.share*'||chr(10)||'  (1+sp.crime';
  if position(marker in fn)=0 then raise exception 'Recruit growth multiplier marker missing'; end if;
  fn:=replace(fn,marker,'p.control/100*p.share*fauxlore.group_status_effect(target_state,''race'',p.race_id,''recruit'')*'||
    'fauxlore.group_status_effect(target_state,''religion'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),''recruit'')*(1+sp.crime');
  marker:='end*p.control/100*p.share,0)),0))';
  if position(marker in fn)=0 then raise exception 'Recruit limit multiplier marker missing'; end if;
  fn:=replace(fn,marker,'end*p.control/100*p.share*fauxlore.group_status_effect(target_state,''race'',p.race_id,''recruit'')*'||
    'fauxlore.group_status_effect(target_state,''religion'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),''recruit''),0)),0))');
  execute fn;
end $$;

-- Status-based production reductions also affect the food balance that drives crime.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.report_food_security_after_turn()'::regprocedure);
  marker:='round(greatest(p.population,0)::numeric*(rc.r->>''production'')::numeric*';
  if position(marker in fn)=0 then raise exception 'Food production marker missing'; end if;
  fn:=replace(fn,marker,'round(greatest(p.population,0)::numeric*(rc.r->>''production'')::numeric*'||
    'fauxlore.group_status_effect(case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'''')) then occupier.id else owner.id end,''race'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''races''),''production'')*'||
    'fauxlore.group_status_effect(case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'''')) then occupier.id else owner.id end,''religion'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),''production'')*');
  execute fn;
end $$;
notify pgrst,'reload schema';
