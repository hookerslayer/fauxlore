-- Approved corruption dynamics and loyalty; configurable additional crime effects.
-- Preserve small overload steps (1001/1000 -> +0.001 percentage points).
alter table fauxlore.state_profiles alter column corruption type numeric(10,7);
update fauxlore.economy_parameters set config=config||jsonb_build_object('stateEffects',jsonb_build_object(
  'crimeTaxPenalty',.25,'crimePopulationPenalty',.5,'crimeRecruitBonus',.5,
  'corruptionTaxPenalty',1,'corruptionLoyaltyDivisor',6,'corruptionLoyaltyCap',.15,
  'overloadCorruptionPerRatio',1,'overloadCorruptionCapPP',3,'corruptionRecoveryCapPP',1,'corruptionGrowthCapPP',3,
  'urbanizationThreshold',.15,'urbanizationPenaltySlope',.5,'urbanizationPenaltyCap',.5)) where singleton;

create or replace function fauxlore.state_tax_breakdown(gross numeric,crime numeric,corruption numeric,cfg jsonb)
returns jsonb language sql immutable set search_path='' as $$
with corruption_loss as (select round(gross*corruption*(cfg#>>'{stateEffects,corruptionTaxPenalty}')::numeric,2) amount),
crime_loss as (select round((gross-c.amount)*crime*(cfg#>>'{stateEffects,crimeTaxPenalty}')::numeric,2) amount from corruption_loss c)
select jsonb_build_object('gross',gross,'corruption_loss',c.amount,'crime_loss',r.amount,'net',gross-c.amount-r.amount)
from corruption_loss c cross join crime_loss r
$$;
revoke all on function fauxlore.state_tax_breakdown(numeric,numeric,numeric,jsonb) from public,anon,authenticated;

create or replace function fauxlore.corruption_step(development numeric,development_limit numeric,stability numeric,cfg jsonb)
returns jsonb language sql immutable set search_path='' as $$
with base as (select case when development_limit=0 then case when coalesce(development,0)>0 then (cfg#>>'{stateEffects,overloadCorruptionCapPP}')::numeric else 0 end
else least((cfg#>>'{stateEffects,overloadCorruptionCapPP}')::numeric,
  greatest(0,coalesce(development,0)-development_limit)/development_limit*(cfg#>>'{stateEffects,overloadCorruptionPerRatio}')::numeric) end overload,
case when stability>=.75 then -1 when stability>=.5 then 0 when stability>=.25 then 1 else 2 end politics)
select jsonb_build_object('corruption_overload_step_pp',overload,'corruption_stability_step_pp',politics,
  'corruption_step_pp',greatest(-(cfg#>>'{stateEffects,corruptionRecoveryCapPP}')::numeric,
    least((cfg#>>'{stateEffects,corruptionGrowthCapPP}')::numeric,overload+politics))) from base
$$;
revoke all on function fauxlore.corruption_step(numeric,numeric,numeric,jsonb) from public,anon,authenticated;

do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.economy_config_api(text,text,jsonb,uuid)'::regprocedure);
  marker:='next_config:=body->''config'';';
  if position(marker in fn)=0 then raise exception 'Config validation marker missing'; end if;
  fn:=replace(fn,marker,marker||$patch$
  if jsonb_typeof(next_config->'stateEffects') is distinct from 'object' then raise sqlstate '22023' using message='Нужны коэффициенты состояния'; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(next_config->'stateEffects') k) is distinct from
    (select array_agg(k order by k) from jsonb_object_keys(old_config->'stateEffects') k) then raise sqlstate '22023' using message='Изменён состав коэффициентов состояния'; end if;
  for pair in select key,value from jsonb_each(next_config->'stateEffects') loop
    if jsonb_typeof(pair.value) is distinct from 'number' then raise sqlstate '22023' using message='Коэффициент состояния должен быть числом'; end if;
    if (pair.value#>>'{}')::numeric<0 or (pair.value#>>'{}')::numeric>100 or
      (pair.key in ('crimeTaxPenalty','crimePopulationPenalty','corruptionTaxPenalty','corruptionLoyaltyCap','urbanizationThreshold','urbanizationPenaltyCap') and (pair.value#>>'{}')::numeric>1) or
      (pair.key='corruptionLoyaltyDivisor' and (pair.value#>>'{}')::numeric<.001) then raise sqlstate '22023' using message='Коэффициент состояния вне допустимого диапазона'; end if;
  end loop;
$patch$);
  execute fn;
end $$;

-- The province appraisal uses the same net tax as the treasury posting.
do $$
declare fn text; marker text:='  production_value:=round(';
begin
  fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Province tax marker missing'; end if;
  execute replace(fn,marker,'  tax_value:=(fauxlore.state_tax_breakdown(tax_value,'||
    'coalesce((select crime from fauxlore.state_profiles where state_id=target_state),.2),'||
    'coalesce((select corruption from fauxlore.state_profiles where state_id=target_state),.2),cfg)->>''net'')::numeric;'||chr(10)||marker);
end $$;

-- Add the non-accumulating bonus to the existing effective-loyalty formula.
do $$
declare fn text; marker text:='loyalty+influence-case status';
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Effective loyalty marker missing'; end if;
  execute replace(fn,marker,'loyalty+case when name in (''Знать'',''Духовенство'') then least((cfg.config#>>''{stateEffects,corruptionLoyaltyCap}'')::numeric,'||
    '(select corruption from fauxlore.state_profiles where state_id=target_state)/(cfg.config#>>''{stateEffects,corruptionLoyaltyDivisor}'')::numeric) else 0 end+influence-case status');
end $$;

create or replace function fauxlore.state_population_growth(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with cfg as (select config from fauxlore.economy_parameters where singleton),
owned as (select p.*,race.name race from fauxlore.provinces p
join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=target_state
left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id where p.kind='land'),
urban as (select coalesce(sum(population*case province_type when 'Столичная' then .35 when 'Городская' then .2 else 0 end)/nullif(sum(population),0),0) ratio from owned),
modifiers as (select greatest(1-(cfg.config#>>'{stateEffects,urbanizationPenaltyCap}')::numeric,
  1-greatest(0,ratio-(cfg.config#>>'{stateEffects,urbanizationThreshold}')::numeric)*(cfg.config#>>'{stateEffects,urbanizationPenaltySlope}')::numeric) urban,
  1-sp.crime*(cfg.config#>>'{stateEffects,crimePopulationPenalty}')::numeric crime,sp.crime crime_rate,sp.corruption
from urban cross join cfg join fauxlore.state_profiles sp on sp.state_id=target_state),
growth as (select case when count(*) filter(where cfg.config#>>array['raceGrowthModifiers',p.race] is null)>0 then null
else coalesce(sum(round(p.population*.03*(cfg.config#>>array['raceGrowthModifiers',p.race])::numeric*m.urban*m.crime,0)),0) end value
from owned p cross join modifiers m cross join cfg)
select jsonb_build_object('urbanization_growth_multiplier',m.urban,'crime_population_growth_multiplier',m.crime,
  'population_growth',g.value,'crime',m.crime_rate,'corruption',m.corruption) from modifiers m cross join growth g
$$;

create or replace function fauxlore.state_recruitment(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with cfg as (select config from fauxlore.economy_parameters where singleton),
provinces as (select p.*,case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then
  case when lower(p.occupation)=lower(target.name) then .5 else 0 end else case when ov.category_id=target_state then 1 else 0 end end share
from fauxlore.provinces p join fauxlore.map_categories target on target.layer='states' and target.id=target_state
left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
where p.kind='land' and (ov.category_id=target_state or lower(p.occupation)=lower(target.name)))
select jsonb_build_object('recruit_growth',coalesce(sum(round(p.population::numeric/1000*(cfg.config#>>array['recruitGrowthModifiers',p.province_type])::numeric*p.control/100*p.share*
  (1+sp.crime*(cfg.config#>>'{stateEffects,crimeRecruitBonus}')::numeric),0)),0),
  'recruit_limit',coalesce(sum(round(p.population::numeric/100*(cfg.config#>>array['recruitLimitModifiers',p.province_type])::numeric*
    case when p.belonging='Отсутствует' then 0 else (cfg.config#>>array['estateRecruitModifiers',p.belonging])::numeric end*p.control/100*p.share,0)),0))
from cfg join fauxlore.state_profiles sp on sp.state_id=target_state left join provinces p on true
$$;
revoke all on function fauxlore.state_recruitment(integer) from public,anon,authenticated;

create or replace function fauxlore.state_indicators(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
select fauxlore.state_indicators_before_urbanization(target_state)||fauxlore.state_population_growth(target_state)||fauxlore.state_recruitment(target_state)||
  jsonb_build_object('corruption_loyalty_bonus',least((cfg.config#>>'{stateEffects,corruptionLoyaltyCap}')::numeric,sp.corruption/(cfg.config#>>'{stateEffects,corruptionLoyaltyDivisor}')::numeric),
    'state_effect_coefficients',cfg.config->'stateEffects')
from fauxlore.economy_parameters cfg join fauxlore.state_profiles sp on sp.state_id=target_state where cfg.singleton
$$;

do $$
declare fn text; marker text:='''occupation_color'',c.color';
begin
  fn:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Occupation map marker missing'; end if;
  execute replace(fn,marker,marker||',''occupation_crime'',coalesce((select crime from fauxlore.state_profiles where state_id=c.id),.2),'||
    '''occupation_corruption'',coalesce((select corruption from fauxlore.state_profiles where state_id=c.id),.2)');
end $$;

-- Post only net tax, while keeping gross and each deduction in the report.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure);
  fn:=replace(fn,'tax_gross numeric;','tax_gross numeric; tax_net numeric; tax_effects jsonb;');
  marker:='belonging text, gross numeric, crown numeric, estate numeric';
  if position(marker in fn)=0 then raise exception 'Turn tax table marker missing'; end if;
  fn:=replace(fn,marker,marker||', corruption_loss numeric, crime_loss numeric, net numeric');
  marker:='    if province_row.belonging is null or province_row.belonging=''Отсутствует'' then';
  if position(marker in fn)=0 then raise exception 'Tax split marker missing'; end if;
  fn:=replace(fn,marker,'    tax_effects:=fauxlore.state_tax_breakdown(tax_gross,'||
    '(select crime from fauxlore.state_profiles where state_id=beneficiary_id),'||
    '(select corruption from fauxlore.state_profiles where state_id=beneficiary_id),cfg);'||chr(10)||
    '    tax_net:=(tax_effects->>''net'')::numeric;'||chr(10)||marker);
  fn:=replace(fn,'split_province_tax(tax_gross,','split_province_tax(tax_net,');
  fn:=replace(fn,'tax_gross,crown_tax,estate_tax);','tax_gross,crown_tax,estate_tax,(tax_effects->>''corruption_loss'')::numeric,(tax_effects->>''crime_loss'')::numeric,tax_net);');
  marker:='''gross_taxes'',round(coalesce(sum(l.gross),0),2),';
  fn:=replace(fn,marker,marker||chr(10)||'      ''corruption_tax_loss'',round(coalesce(sum(l.corruption_loss),0),2),'||
    '''crime_tax_loss'',round(coalesce(sum(l.crime_loss),0),2),''net_taxes'',round(coalesce(sum(l.net),0),2),');
  fn:=replace(fn,'''gross'',l.gross,''crown'',l.crown','''gross'',l.gross,''corruption_loss'',l.corruption_loss,''crime_loss'',l.crime_loss,''net'',l.net,''crown'',l.crown');
  execute fn;
end $$;

-- Freeze corruption inputs before mutating either rate. The same trigger
-- still computes all production/food with opening crime, then writes rates.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.report_food_security_after_turn()'::regprocedure);
  fn:=replace(fn,'next_crime numeric;','next_crime numeric; corruption_steps jsonb; next_corruption numeric; effects_config jsonb;');
  marker:='    indicators:=fauxlore.state_indicators(state_row.state_id);';
  if position(marker in fn)=0 then raise exception 'Opening indicators marker missing'; end if;
  fn:=replace(fn,marker,marker||chr(10)||'    select config into effects_config from fauxlore.economy_parameters where singleton;'||chr(10)||
    '    corruption_steps:=fauxlore.corruption_step((indicators->>''total_development'')::numeric,(indicators->>''development_limit'')::numeric,(indicators->>''stability'')::numeric,effects_config);'||chr(10)||
    '    next_corruption:=round(greatest(.02,least(.9,(indicators->>''corruption'')::numeric+(corruption_steps->>''corruption_step_pp'')::numeric/100)),7);');
  marker:='''crime_change_pp'',round((next_crime-state_crime)*100,2)';
  if position(marker in fn)=0 then raise exception 'Crime report marker missing'; end if;
  fn:=replace(fn,marker,marker||','||chr(10)||
    '      ''corruption_rate_at_turn_start_pct'',(indicators->>''corruption'')::numeric*100,''corruption_rate_after_pct'',next_corruption*100,'||chr(10)||
    '      ''corruption_change_pp'',round((next_corruption-(indicators->>''corruption'')::numeric)*100,5),'||chr(10)||
    '      ''corruption_overload_step_pp'',corruption_steps->''corruption_overload_step_pp'',''corruption_stability_step_pp'',corruption_steps->''corruption_stability_step_pp'',''corruption_step_pp'',corruption_steps->''corruption_step_pp'','||chr(10)||
    '      ''state_effect_coefficients'',effects_config->''stateEffects'',''corruption_loyalty_bonus_at_start_pp'',(indicators->>''corruption_loyalty_bonus'')::numeric*100,'||chr(10)||
    '      ''corruption_loyalty_bonus_next_pp'',least((effects_config#>>''{stateEffects,corruptionLoyaltyCap}'')::numeric,next_corruption/(effects_config#>>''{stateEffects,corruptionLoyaltyDivisor}'')::numeric)*100');
  fn:=replace(fn,'set crime=(r->>''crime_rate_after_pct'')::numeric/100','set crime=(r->>''crime_rate_after_pct'')::numeric/100,corruption=(r->>''corruption_rate_after_pct'')::numeric/100');
  execute fn;
end $$;
notify pgrst,'reload schema';
