-- Apply active political modifiers to the authoritative stability calculation.
create or replace function fauxlore.state_group_permanent_loyalty(
  target_state integer, group_kind text, category_key integer
) returns numeric language sql stable security definer set search_path='' as $function$
with target_group as (
  select c.name,coalesce(g.status,
    case when group_kind='race' and sp.official_race_id=category_key
      or group_kind='religion' and sp.official_religion_id=category_key
      then 'Официальная' else 'Невмешательство' end) status
  from fauxlore.map_categories c
  join fauxlore.state_profiles sp on sp.state_id=target_state
  left join fauxlore.state_group_politics g on g.state_id=target_state
    and g.group_type=group_kind and g.group_key=category_key::text
  where c.id=category_key and c.layer=case group_kind when 'race' then 'races' else 'religions' end
)
select coalesce(sum((m.value->>'value')::numeric),0)
from target_group t
cross join lateral jsonb_array_elements(fauxlore.state_permanent_modifiers(target_state)) m(value)
where m.value->>'key'=case group_kind when 'race' then 'other_race_loyalty' else 'other_religion_loyalty' end
  and t.status in ('Невмешательство','Ассимиляция','Истребление')
  and (m.value->>'source_kind'<>'admin' or m.value->>'target_province_id' is null)
  and (m.value->>'source_kind'='admin' or m.value->>'source'<>t.name)
$function$;
revoke all on function fauxlore.state_group_permanent_loyalty(integer,text,integer) from public,anon,authenticated;

do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  old_fragment:='coalesce(sum(fauxlore.province_value_for_state(p.id,target_state)*ep.population/nullif(p.population,0)),0) weight,';
  new_fragment:='coalesce(sum(fauxlore.province_value_for_state(p.id,target_state)*ep.population/nullif(p.population,0)*case coalesce(g.status,fauxlore.estate_status_for(target_state,e.name)) when ''Ключевое'' then 3 when ''Значимое'' then 1.5 when ''Бесправное'' then .25 else 1 end),0) weight,';
  if position(old_fragment in fn)>0 then fn:=replace(fn,old_fragment,new_fragment);
  elsif position(new_fragment in fn)=0 then raise exception 'Estate status weight formula changed'; end if;

  old_fragment:='select *,coalesce(weight/nullif(sum(weight) over(),0),0) influence from estates';
  new_fragment:='select *,coalesce(adjusted_weight/nullif(sum(adjusted_weight) over(),0),0) influence from (select estates.*,weight*case when name=''Крестьяне'' then greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,array[''peasant_influence''],null,null)) else 1 end adjusted_weight from estates) weighted';
  if position(old_fragment in fn)=0 then raise exception 'Estate influence formula changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='else 0 end+influence-case status';
  new_fragment:='else 0 end+fauxlore.state_permanent_modifier_total(target_state,array[''estate_loyalty''],null,null)+case name when ''Знать'' then fauxlore.state_permanent_modifier_total(target_state,array[''nobility_loyalty''],null,null) when ''Крестьяне'' then fauxlore.state_permanent_modifier_total(target_state,array[''peasant_loyalty''],null,null) else 0 end+influence-case status';
  if position(old_fragment in fn)=0 then raise exception 'Estate loyalty formula changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='coalesce(gp.loyalty,.5)+fauxlore.group_status_loyalty_modifier(target_state,case l.layer when ''races'' then ''race'' else ''religion'' end,g.category_id)';
  new_fragment:=old_fragment||'+fauxlore.state_group_permanent_loyalty(target_state,case l.layer when ''races'' then ''race'' else ''religion'' end,g.category_id)';
  if position(old_fragment in fn)=0 then raise exception 'Group loyalty formula changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  execute fn;
end
$migration$;

-- The base rate is a reference value. Show the actual province range too.
create or replace function fauxlore.state_indicators(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $function$
select fauxlore.state_indicators_before_urbanization(target_state)
  ||fauxlore.state_population_growth(target_state)
  ||fauxlore.state_recruitment(target_state)
  ||jsonb_build_object(
    'corruption_loyalty_bonus',least((cfg.config#>>'{stateEffects,corruptionLoyaltyCap}')::numeric,sp.corruption/(cfg.config#>>'{stateEffects,corruptionLoyaltyDivisor}')::numeric),
    'base_tax_efficiency',fauxlore.province_tax_efficiency_base(),
    'effective_tax_efficiency_min',rates.min_rate,
    'effective_tax_efficiency_max',rates.max_rate,
    'state_effect_coefficients',cfg.config->'stateEffects',
    'permanent_modifiers',fauxlore.state_permanent_modifiers(target_state))
from fauxlore.economy_parameters cfg
join fauxlore.state_profiles sp on sp.state_id=target_state
cross join lateral (
  select min(fauxlore.effective_province_tax_efficiency(target_state,p.id)) min_rate,
         max(fauxlore.effective_province_tax_efficiency(target_state,p.id)) max_rate
  from fauxlore.provinces p
  join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states' and owner.category_id=target_state
  where p.kind='land'
) rates
where cfg.singleton
$function$;
revoke all on function fauxlore.state_indicators(integer) from public,anon;
grant execute on function fauxlore.state_indicators(integer) to authenticated;
notify pgrst,'reload schema';
