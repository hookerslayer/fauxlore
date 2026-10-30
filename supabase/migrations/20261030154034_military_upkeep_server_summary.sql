create or replace function fauxlore.military_upkeep_summary(target_state integer)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare
  army_cost numeric:=0;
  fleet_cost numeric:=0;
  militia_cost numeric:=0;
  mercenary_cost numeric:=0;
  garrison_cost numeric:=0;
begin
  select coalesce(sum(floor(u.upkeep*fauxlore.military_unit_cost_factor(target_state,u.id,'upkeep')*
    greatest(0,fu.quantity-case when u.name='Копейщик' then least(fu.quantity,coalesce(f.free_upkeep_quantity,0)) else 0 end)))
      filter(where f.domain='land'),0),
    coalesce(sum(floor(u.upkeep*fauxlore.military_unit_cost_factor(target_state,u.id,'upkeep')*
    greatest(0,fu.quantity-case when u.name='Копейщик' then least(fu.quantity,coalesce(f.free_upkeep_quantity,0)) else 0 end)))
      filter(where f.domain='naval'),0)
  into army_cost,fleet_cost
  from fauxlore.military_formations f join fauxlore.military_formation_units fu on fu.formation_id=f.id
    join fauxlore.military_unit_catalog u on u.id=fu.unit_id
  where f.state_id=target_state and f.active and f.kind='regular';
  select coalesce(sum(fu.quantity*u.upkeep),0) into militia_cost
  from fauxlore.military_formations f join fauxlore.military_formation_units fu on fu.formation_id=f.id
    join fauxlore.military_unit_catalog u on u.id=fu.unit_id
  where f.state_id=target_state and f.active and f.kind='militia';
  select coalesce(sum(g.price*greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,
    array['mercenary_upkeep'],null,null))),0) into mercenary_cost
  from fauxlore.military_formations f join fauxlore.mercenary_groups g on g.id=f.mercenary_group_id
  where f.state_id=target_state and f.active and f.kind='mercenary';
  garrison_cost:=fauxlore.garrison_upkeep(target_state);
  return jsonb_build_object('army',army_cost,'fleet',fleet_cost,'militia',militia_cost,
    'mercenaries',mercenary_cost,'garrisons',garrison_cost,
    'total',army_cost+fleet_cost+militia_cost+mercenary_cost+garrison_cost);
end
$function$;
revoke all on function fauxlore.military_upkeep_summary(integer) from public,anon,authenticated;

do $migration$
declare
  definition text;
  marker text := '''state_id'',sid,''is_admin'',is_admin,';
begin
  definition:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  if position(marker in definition)=0 then raise exception 'Military snapshot header changed'; end if;
  definition:=replace(definition,marker,marker||E'\n   '||'''upkeep_breakdown'',fauxlore.military_upkeep_summary(sid),');
  execute definition;
end
$migration$;
