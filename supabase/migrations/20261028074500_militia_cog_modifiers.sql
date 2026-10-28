-- Add principle-granted cogs to estate militia as a separate militia fleet.
alter table fauxlore.militia_calls
  add column if not exists naval_formation_id bigint references fauxlore.military_formations(id) on delete set null;

create or replace function fauxlore.militia_cog_plan(state_key integer)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare modifier_row jsonb; threshold_value integer; coastal_development bigint; cog_count integer;
  state_name text; port_row record; crew_cost integer; reserve_value integer;
begin
  select value into modifier_row
  from jsonb_array_elements(fauxlore.state_permanent_modifiers(state_key)) value
  where value->>'key'='militia_cog_per_development'
  order by (value->>'value')::numeric desc limit 1;
  if modifier_row is null then return '[]'::jsonb; end if;
  threshold_value:=substring(modifier_row->>'unit' from '/([0-9]+) развития')::integer;
  if threshold_value is null or threshold_value<1 then return '[]'::jsonb; end if;
  select recruit_cost into crew_cost from fauxlore.military_unit_catalog
    where name='Когг' and domain='naval' and state_id is null and active order by version desc limit 1;
  select recruits into reserve_value from fauxlore.state_profiles where state_id=state_key;
  if coalesce(crew_cost,0)<1 then return '[]'::jsonb; end if;
  select name into state_name from fauxlore.map_categories where layer='states' and id=state_key;
  select coalesce(sum(p.development),0)::bigint into coastal_development
  from fauxlore.provinces p
  join fauxlore.province_values owner_value on owner_value.province_id=p.id
    and owner_value.layer='states' and owner_value.category_id=state_key
  cross join fauxlore.map_adjacency graph
  where graph.singleton and p.kind='land'
    and (p.occupation is null or lower(p.occupation)=lower(state_name))
    and exists(
      select 1 from jsonb_array_elements_text(coalesce(graph.neighbors->p.id::text,'[]'::jsonb)) neighbor(value)
      join fauxlore.provinces sea on sea.id=neighbor.value::integer and sea.kind='sea'
      where exists(select 1 from fauxlore.military_accessible_port(state_key,sea.id))
    );
  cog_count:=least(floor(coastal_development::numeric/threshold_value)::integer,
    floor(coalesce(reserve_value,0)::numeric/crew_cost)::integer);
  if cog_count<1 then return '[]'::jsonb; end if;
  select sea.id sea_province,port.marker_id,port.x,port.y into port_row
  from fauxlore.provinces sea
  cross join lateral fauxlore.military_accessible_port(state_key,sea.id) port
  cross join fauxlore.map_adjacency graph
  where graph.singleton and sea.kind='sea'
    and exists(
      select 1 from jsonb_array_elements_text(coalesce(graph.neighbors->sea.id::text,'[]'::jsonb)) neighbor(value)
      join fauxlore.provinces land on land.id=neighbor.value::integer and land.kind='land'
      join fauxlore.province_values owner_value on owner_value.province_id=land.id
        and owner_value.layer='states' and owner_value.category_id=state_key
      where land.occupation is null or lower(land.occupation)=lower(state_name)
    )
  order by case when exists(select 1 from fauxlore.map_markers own_port
      where own_port.id=port.marker_id and own_port.state_id=state_key) then 0 else 1 end,port.marker_id
  limit 1;
  if not found then return '[]'::jsonb; end if;
  return jsonb_build_array(jsonb_build_object('province_id',port_row.sea_province,
    'port_marker_id',port_row.marker_id,'x',port_row.x,'y',port_row.y,'cogs',cog_count,
    'crew_recruits',cog_count*crew_cost));
end $function$;
revoke all on function fauxlore.militia_cog_plan(integer) from public,anon,authenticated;

-- Attach the cog forecast to the existing militia preview shown to players.
do $patch$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.militia_preview(integer)'::regprocedure);
  marker:=$m$return jsonb_build_object('doctrine',doctrine_value,'coefficient',coeff,'total',grand_total,$m$;
  if position(marker in definition)=0 then raise exception 'Militia preview output marker not found'; end if;
  execute replace(definition,marker,marker||E'\n    ''naval_fleets'',fauxlore.militia_cog_plan(state_key),');
end
$patch$;

-- Create a naval militia formation at an accessible port when the approved call resolves.
do $patch$
declare definition text; marker text; replacement text;
begin
  definition:=pg_get_functiondef('fauxlore.advance_militia_turn()'::regprocedure);
  marker:='perform fauxlore.ensure_state_group_politics(militia_row.state_id);';
  replacement:=$insert$
    naval_formation_key:=null;
    fleet_index:=0;
    for naval_row in select (item->>'province_id')::integer province_id,(item->>'port_marker_id')::bigint port_marker_id,
      (item->>'x')::double precision x,(item->>'y')::double precision y,(item->>'cogs')::integer cogs
      from jsonb_array_elements(coalesce(plan_value->'naval_fleets','[]'::jsonb)) item loop
      fleet_index:=fleet_index+1;
      select recruit_cost into crew_cost from fauxlore.military_unit_catalog
        where name='Когг' and domain='naval' and state_id is null and active order by version desc limit 1;
      if crew_cost is null or crew_cost<1 then raise exception 'Militia naval unit Когг has no crew cost'; end if;
      select recruits into reserve_value from fauxlore.state_profiles where state_id=militia_row.state_id for update;
      actual_cogs:=least(naval_row.cogs,floor(coalesce(reserve_value,0)::numeric/crew_cost)::integer);
      plan_value:=jsonb_set(plan_value,array['naval_fleets',(fleet_index-1)::text,'cogs'],to_jsonb(actual_cogs));
      plan_value:=jsonb_set(plan_value,array['naval_fleets',(fleet_index-1)::text,'crew_recruits'],to_jsonb(actual_cogs*crew_cost));
      if actual_cogs<1 then continue; end if;
      update fauxlore.state_profiles set recruits=recruits-actual_cogs*crew_cost where state_id=militia_row.state_id;
      insert into fauxlore.military_formations(state_id,name,domain,kind,province_id,position_x,position_y)
        values(militia_row.state_id,'Когги ополчения','naval','militia',naval_row.province_id,naval_row.x,naval_row.y)
        returning id into naval_formation_key;
      insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
        select naval_formation_key,u.id,actual_cogs from fauxlore.military_unit_catalog u
        where u.name='Когг' and u.domain='naval' and u.state_id is null and u.active order by u.version desc limit 1;
      if not found then raise exception 'Militia naval unit Когг is missing from catalog'; end if;
    end loop;
    $insert$||E'\n    '||marker;
  if position(marker in definition)=0 then raise exception 'Militia turn insertion point not found'; end if;
  definition:=replace(definition,'home_province integer; formation_key bigint; state_name text; loyalty_entry record;','home_province integer; formation_key bigint; naval_formation_key bigint; naval_row record; crew_cost integer; reserve_value integer; actual_cogs integer; fleet_index integer; state_name text; loyalty_entry record;');
  definition:=replace(definition,marker,replacement);
  marker:='formation_id=formation_key,';
  if position(marker in definition)=0 then raise exception 'Militia active-call update marker not found'; end if;
  definition:=replace(definition,marker,marker||E'\n      naval_formation_id=naval_formation_key,');
  execute definition;
end
$patch$;

-- Include naval militia in upkeep, charge it to the Crown, and show it in forecasts.
do $patch$
declare definition text; marker text; replacement text;
begin
  definition:=pg_get_functiondef('fauxlore.charge_militia_before_turn()'::regprocedure);
  definition:=replace(definition,'total_cost bigint;','total_cost bigint; fleet_cost bigint;');
  marker:=$m$where fu.formation_id=militia_row.formation_id;$m$;
  replacement:=$m$where fu.formation_id=militia_row.formation_id;
    select floor(coalesce(sum(nfu.quantity::numeric*nu.upkeep),0))::bigint into fleet_cost
      from fauxlore.military_formations nf
      join fauxlore.military_formation_units nfu on nfu.formation_id=nf.id
      join fauxlore.military_unit_catalog nu on nu.id=nfu.unit_id
      where nf.id=militia_row.naval_formation_id and nf.active and nf.kind='militia';$m$;
  if position(marker in definition)=0 then raise exception 'Militia upkeep query marker not found'; end if;
  definition:=replace(definition,marker,replacement);
  definition:=replace(definition,'crown_cost:=total_cost-burgher_cost-peasant_cost-noble_cost;','crown_cost:=total_cost+coalesce(fleet_cost,0)-burgher_cost-peasant_cost-noble_cost;');
  definition:=replace(definition,'''militia_upkeep'',total_cost,','''militia_upkeep'',total_cost+coalesce(fleet_cost,0),');
  definition:=replace(definition,'''army_upkeep'',coalesce((entry.value->>''army_upkeep'')::numeric,0)+total_cost,','''army_upkeep'',coalesce((entry.value->>''army_upkeep'')::numeric,0)+total_cost+coalesce(fleet_cost,0),');
  definition:=replace(definition,'''army_upkeep_paid'',coalesce((entry.value->>''army_upkeep_paid'')::numeric,0)+total_cost,','''army_upkeep_paid'',coalesce((entry.value->>''army_upkeep_paid'')::numeric,0)+total_cost+coalesce(fleet_cost,0),');
  execute definition;

  definition:=pg_get_functiondef('fauxlore.militia_crown_upkeep(integer)'::regprocedure);
  marker:=$m$floor(coalesce(sum(fu.quantity::numeric*u.upkeep),0))::bigint total_cost$m$;
  replacement:=$m$floor(coalesce(sum(fu.quantity::numeric*u.upkeep),0))::bigint total_cost,
    coalesce((select floor(coalesce(sum(nfu.quantity::numeric*nu.upkeep),0))::bigint
    from fauxlore.military_formations nf
    join fauxlore.military_formation_units nfu on nfu.formation_id=nf.id
    join fauxlore.military_unit_catalog nu on nu.id=nfu.unit_id
    where nf.state_id=m.state_id and nf.active and nf.kind='militia' and nf.domain='naval'),0) fleet_cost$m$;
  if position(marker in definition)=0 then raise exception 'Militia forecast upkeep marker not found'; end if;
  definition:=replace(definition,marker,replacement);
  definition:=replace(definition,'then total_cost'||E'\n    -floor','then total_cost+fleet_cost'||E'\n    -floor');
  definition:=replace(definition,'then total_cost-floor(total_cost*.7)','then total_cost+fleet_cost-floor(total_cost*.7)');
  definition:=replace(definition,'else total_cost end from active_call','else total_cost+fleet_cost end from active_call');
  execute definition;

  definition:=pg_get_functiondef('public.militia_api(text,integer,jsonb)'::regprocedure);
  marker:='update fauxlore.military_formations set active=false where id=call_row.formation_id and state_id=sid and kind=''militia'';';
  replacement:=marker||E'\n    update fauxlore.military_formations set active=false where id=call_row.naval_formation_id and state_id=sid and kind=''militia'';';
  if position(marker in definition)=0 then raise exception 'Militia disband marker not found'; end if;
  definition:=replace(definition,marker,replacement);
  marker:='formation_id=null,plan=excluded.plan,updated_at=now();';
  replacement:='formation_id=null,naval_formation_id=null,plan=excluded.plan,updated_at=now();';
  if position(marker in definition)=0 then raise exception 'Militia resubmission marker not found'; end if;
  execute replace(definition,marker,replacement);
end
$patch$;

notify pgrst,'reload schema';
