-- Apply permanent state, principle, race and religion modifiers to garrison limits,
-- garrison upkeep and garrison hire costs.

create or replace function fauxlore.garrison_capacity(province_key integer)
returns integer
language sql stable security definer set search_path=''
as $function$
with base as (
  select coalesce(p.development,0)*case p.province_type
      when 'Столичная' then 3 when 'Городская' then 2 when 'Регион' then 1 else 0 end
    +case coalesce(g.fort_level,0) when 1 then 100 when 2 then 300 when 3 then 800 when 4 then 1300 else 0 end
    +case coalesce(g.wall_level,0) when 1 then 500 when 2 then 1000 when 3 then 2000 else 0 end as value,
    coalesce(g.state_id,owner.category_id) as state_id
  from fauxlore.provinces p
  left join fauxlore.garrison_sites g on g.province_id=p.id
  left join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states'
  where p.id=province_key
)
select floor(greatest(0,base.value)*(1+fauxlore.state_permanent_modifier_total(
  base.state_id,array['garrison_limit'],province_key,null)))::integer
from base
$function$;
revoke all on function fauxlore.garrison_capacity(integer) from public,anon,authenticated;

create or replace function fauxlore.garrison_site_upkeep(province_key integer)
returns numeric language sql stable security definer set search_path=''
as $function$
with site as (
  select g.*,coalesce(g.state_id,owner.category_id) as modifier_state
  from fauxlore.garrison_sites g
  left join fauxlore.province_values owner on owner.province_id=g.province_id and owner.layer='states'
  where g.province_id=province_key
), base as (
  select coalesce((select sum(round(u.quantity*c.upkeep*.4,2)) from fauxlore.garrison_units u
      join fauxlore.military_unit_catalog c on c.id=u.unit_id where u.province_id=s.province_id),0) as troop_cost,
    greatest(0,(case s.fort_level when 1 then 100 when 2 then 200 when 3 then 300 when 4 then 400 else 0 end)
      -case when s.free_fort then 300 else 0 end)
    +greatest(0,(case s.wall_level when 1 then 300 when 2 then 500 when 3 then 700 else 0 end)
      -case when s.free_wall then 300 else 0 end) as fort_cost,
    s.modifier_state,s.province_id
  from site s
)
select floor(greatest(0,base.troop_cost)*(1+fauxlore.state_permanent_modifier_total(
    base.modifier_state,array['garrison_upkeep'],base.province_id,null)))
  +floor(greatest(0,base.fort_cost)*(1+fauxlore.state_permanent_modifier_total(
    base.modifier_state,array['fortification_upkeep'],null,null)))
from base
$function$;
revoke all on function fauxlore.garrison_site_upkeep(integer) from public,anon,authenticated;

create or replace function fauxlore.garrison_upkeep(state_key integer)
returns numeric language sql stable security definer set search_path=''
as $function$
select coalesce(sum(fauxlore.garrison_site_upkeep(g.province_id)),0)
from fauxlore.garrison_sites g where g.state_id=state_key
$function$;
revoke all on function fauxlore.garrison_upkeep(integer) from public,anon,authenticated;

do $patch$
declare definition text; marker text:='cost_value:=round(quantity_value*unit_row.hire_cost*.7,2);';
begin
  select pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure) into definition;
  if position(marker in definition)=0 then
    raise exception 'Could not locate garrison hire cost calculation';
  end if;
  definition:=replace(definition,marker,
    'cost_value:=floor(quantity_value*unit_row.hire_cost*.7*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array[''garrison_hire_cost''],province_key,null)));');
  execute definition;
end
$patch$;
