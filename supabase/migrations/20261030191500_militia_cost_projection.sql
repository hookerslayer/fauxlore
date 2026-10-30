-- Keep militia upkeep and estate funding forecasts on the server.
do $$
declare definition text; marker text; replacement text;
begin
  definition:=pg_get_functiondef('fauxlore.militia_preview(integer)'::regprocedure);
  definition:=replace(definition,
    '  unit_row record; unit_names text[]; shares numeric[];',
    '  unit_row record; unit_names text[]; shares numeric[]; land_upkeep integer:=0; naval_upkeep integer:=0; total_upkeep integer:=0; funding jsonb; burgher_cost integer:=0; peasant_cost integer:=0; noble_cost integer:=0; burgher_count integer:=0; peasant_count integer:=0;');
  marker:=$old$  return jsonb_build_object('doctrine',doctrine_value,'coefficient',coeff,'total',grand_total,$old$;
  replacement:=$new$  select floor(coalesce(sum((item.value)::integer*u.upkeep),0))::integer into land_upkeep
    from jsonb_each_text(units) item join fauxlore.military_unit_catalog u on u.name=item.key
    where u.state_id is null and u.active;
  select floor(coalesce(sum((fleet.value->>'cogs')::integer*u.upkeep),0))::integer into naval_upkeep
    from jsonb_array_elements(fauxlore.militia_cog_plan(state_key)) fleet(value)
    join fauxlore.military_unit_catalog u on u.name='Когг' and u.domain='naval' and u.state_id is null and u.active;
  total_upkeep:=land_upkeep+naval_upkeep;
  burgher_count:=coalesce((contributions->>'Горожане')::integer,0);
  peasant_count:=coalesce((contributions->>'Крестьяне')::integer,0);
  if doctrine_value='Фирд' and burgher_count+peasant_count>0 then
    burgher_cost:=floor(land_upkeep*.6*burgher_count/(burgher_count+peasant_count));
    peasant_cost:=floor(land_upkeep*.6*peasant_count/(burgher_count+peasant_count));
  elsif doctrine_value='Сословная армия' then
    noble_cost:=floor(land_upkeep*.7);
  end if;
  funding:=jsonb_build_object('Корона',total_upkeep-burgher_cost-peasant_cost-noble_cost,
    'Знать',noble_cost,'Духовенство',0,'Горожане',burgher_cost,'Крестьяне',peasant_cost);
  return jsonb_build_object('doctrine',doctrine_value,'coefficient',coeff,'total',grand_total,
    'upkeep',total_upkeep,'funding_by_estate',funding,
    'naval_crew_recruits',coalesce((select sum((fleet.value->>'crew_recruits')::integer)
      from jsonb_array_elements(fauxlore.militia_cog_plan(state_key)) fleet(value)),0),$new$;
  if position(marker in definition)=0 then raise exception 'Militia preview output marker not found'; end if;
  execute replace(definition,marker,replacement);
end $$;

notify pgrst,'reload schema';
