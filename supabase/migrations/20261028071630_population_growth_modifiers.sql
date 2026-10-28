-- Apply local race population-growth modifiers to the authoritative yearly
-- settlement and use the project's downward integer rounding rule.
do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.apply_turn_population_and_recruit_growth()'::regprocedure) into definition;
  marker:=$m$province_growth:=floor(province_row.population*.015*(cfg#>>array['raceGrowthModifiers',province_row.race])::numeric
        *(indicators->>'urbanization_growth_multiplier')::numeric
        *(indicators->>'crime_population_growth_multiplier')::numeric
        *greatest(0,coalesce(province_row.development,100))::numeric/100
        *fauxlore.group_status_effect(state_row.state_id,'race',province_row.race_id,'population')
        *fauxlore.group_status_effect(state_row.state_id,'religion',province_row.religion_id,'population'))::integer;$m$;
  replacement:=$m$province_growth:=floor(province_row.population*.015*(cfg#>>array['raceGrowthModifiers',province_row.race])::numeric
        *(indicators->>'urbanization_growth_multiplier')::numeric
        *(indicators->>'crime_population_growth_multiplier')::numeric
        *greatest(0,coalesce(province_row.development,100))::numeric/100
        *fauxlore.group_status_effect(state_row.state_id,'race',province_row.race_id,'population')
        *fauxlore.group_status_effect(state_row.state_id,'religion',province_row.religion_id,'population')
        *(1+fauxlore.state_permanent_modifier_total(state_row.state_id,array['population_growth','livestock_population_growth'],province_row.id,null)))::integer;$m$;
  if position(marker in definition)=0 then raise exception 'Could not locate population growth formula'; end if;
  execute replace(definition,marker,replacement);
end
$patch$;
