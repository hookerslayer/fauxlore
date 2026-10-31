-- Restrict resource-specific production bonuses to their actual goods.
do $migration$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  marker:=$old$    if row_value->>'key'='precious_consumption'$old$;
  if position(marker in fn)=0 then raise exception 'Modifier resource check changed'; end if;
  fn:=replace(fn,marker,$new$    if row_value->>'key'='metal_production' and target_resource is distinct from 'Металлы' and target_resource is distinct from 'Драгоценные металлы' then continue; end if;
    if row_value->>'key'='ephemera_production' and target_resource is distinct from 'Эфемера' then continue; end if;
$new$||marker);
  execute fn;
end $migration$;

-- Keep market supply, food security and contract availability consistent with
-- the production and consumption modifiers used in the resource turn report.
do $migration$
declare fn text; old_part text; new_part text; proc regprocedure;
  controller text:=$s$case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end$s$;
  production_factor text;
begin
  production_factor:='*greatest(0,1+fauxlore.state_permanent_modifier_total('||controller||',array[''production'',''urban_production'',''regional_production'',''metal_production'',''ephemera_production''],p.id,resource.name))';
  foreach proc in array array['fauxlore.clear_trade_zones_after_budget()'::regprocedure,'fauxlore.trade_resource_surplus(integer,text)'::regprocedure,'fauxlore.report_food_security_after_turn()'::regprocedure] loop
    fn:=pg_get_functiondef(proc);
    old_part:=$s$coalesce(p.control,100)::numeric/100*greatest(0,coalesce(p.development,100))::numeric/100*(1-coalesce(owner_profile.crime,.2))$s$;
    if position(old_part in fn)=0 then raise exception 'Production formula changed in %',proc; end if;
    fn:=replace(fn,old_part,old_part||production_factor);
    if proc='fauxlore.clear_trade_zones_after_budget()'::regprocedure then
      old_part:=$s$floor(zp.population/10*(rc.r->>'consumption')::numeric)$s$;
      new_part:=$s$floor(zp.population/10*(rc.r->>'consumption')::numeric*greatest(0,1+fauxlore.state_permanent_modifier_total(zp.state_id,array['consumption','other_consumption','precious_consumption'],null,rc.r->>'name')))$s$;
    elsif proc='fauxlore.trade_resource_surplus(integer,text)'::regprocedure then
      old_part:=$s$floor(owned_population.amount/10*(resource_config.r->>'consumption')::numeric)$s$;
      new_part:=$s$floor(owned_population.amount/10*(resource_config.r->>'consumption')::numeric*greatest(0,1+fauxlore.state_permanent_modifier_total(state_value,array['consumption','other_consumption','precious_consumption'],null,resource_value)))$s$;
    else
      old_part:=$s$floor(op.population/10*f.consumption)$s$;
      new_part:=$s$floor(op.population/10*f.consumption*greatest(0,1+fauxlore.state_permanent_modifier_total(op.state_id,array['consumption','other_consumption','precious_consumption'],null,f.name)))$s$;
    end if;
    if position(old_part in fn)=0 then raise exception 'Consumption formula changed in %',proc; end if;
    execute replace(fn,old_part,new_part);
  end loop;
end $migration$;

-- Use the actual provincial resource in both the turn and the state forecast.
do $migration$
declare fn text; old_part text; resource_lookup text:=$s$(select c.name from fauxlore.province_values v join fauxlore.map_categories c on c.layer='resources' and c.id=v.category_id where v.province_id=province_row.id and v.layer='resources')$s$;
begin
  fn:=pg_get_functiondef('fauxlore.apply_turn_population_and_recruit_growth()'::regprocedure);
  old_part:=$s$province_row.id,null)))::integer$s$;
  if position(old_part in fn)=0 then raise exception 'Population turn formula changed'; end if;
  execute replace(fn,old_part,'province_row.id,'||resource_lookup||')))::integer');

  fn:=pg_get_functiondef('fauxlore.state_population_growth(integer)'::regprocedure);
  old_part:=$s$fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'population'))),0)$s$;
  if position(old_part in fn)=0 then raise exception 'Population forecast formula changed'; end if;
  execute replace(fn,old_part,$s$fauxlore.group_status_effect(target_state,'religion',(select category_id from fauxlore.province_values where province_id=p.id and layer='religions'),'population')*greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,array['population_growth','livestock_population_growth'],p.id,(select c.name from fauxlore.province_values v join fauxlore.map_categories c on c.layer='resources' and c.id=v.category_id where v.province_id=p.id and v.layer='resources'))))),0)$s$);
end $migration$;

-- Annotate conditions for display without introducing recursion in the raw
-- modifier list used to calculate effective loyalty.
create or replace function fauxlore.state_permanent_modifiers_for_display(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $function$
with loyalty as materialized (select * from fauxlore.effective_estate_loyalties(target_state)),
items as (select value,ord from jsonb_array_elements(fauxlore.state_permanent_modifiers(target_state)) with ordinality as t(value,ord))
select coalesce(jsonb_agg(value||jsonb_build_object('status',case
  when value->>'condition'='Лояльность Знати выше 60%' and coalesce((select effective_loyalty from loyalty where name='Знать'),0)<=.60 then 'Условие не выполнено'
  when value->>'condition'='Лояльность ключевых сословий выше 60%' and
    (not exists(select 1 from loyalty where status='Ключевое') or exists(select 1 from loyalty where status='Ключевое' and effective_loyalty<=.60)) then 'Условие не выполнено'
  else value->>'status' end) order by ord),'[]'::jsonb) from items
$function$;
revoke all on function fauxlore.state_permanent_modifiers_for_display(integer) from public,anon,authenticated;
do $migration$
declare fn text; old_part text:=$s$'permanent_modifiers',fauxlore.state_permanent_modifiers(target_state)$s$;
begin
  fn:=pg_get_functiondef('fauxlore.state_indicators(integer)'::regprocedure);
  if position(old_part in fn)=0 then raise exception 'Modifier display source changed'; end if;
  execute replace(fn,old_part,$s$'permanent_modifiers',fauxlore.state_permanent_modifiers_for_display(target_state)$s$);
end $migration$;
