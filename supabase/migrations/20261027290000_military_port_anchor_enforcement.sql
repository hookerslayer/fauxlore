-- A naval formation is in port only while its coordinates match an accessible port marker.
create or replace function fauxlore.military_accessible_port(state_value integer,sea_province integer)
returns table(marker_id bigint,x double precision,y double precision)
language sql stable security definer set search_path='' as $function$
  select marker.id,marker.x,marker.y
  from fauxlore.map_markers marker
  join fauxlore.map_adjacency graph on graph.singleton
  cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->sea_province::text,'[]'::jsonb)) near_land(value)
  join fauxlore.provinces land on land.id=near_land.value::integer and land.kind='land'
  left join fauxlore.province_values owner_value on owner_value.province_id=land.id and owner_value.layer='states'
  left join fauxlore.map_categories owner_state on owner_state.layer='states' and owner_state.id=owner_value.category_id
  left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(land.occupation)
  where marker.type='port' and marker.province_id=sea_province
    and (marker.state_id=state_value or coalesce(occupier.id,owner_state.id)=state_value
      or exists(select 1 from fauxlore.military_diplomacy passage
        where passage.kind='passage' and passage.status='accepted'
          and ((passage.from_state_id=state_value and passage.to_state_id=coalesce(occupier.id,owner_state.id))
            or (passage.to_state_id=state_value and passage.from_state_id=coalesce(occupier.id,owner_state.id)))))
  order by case when marker.state_id=state_value then 0 else 1 end,marker.id
$function$;
revoke all on function fauxlore.military_accessible_port(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.military_port_accessible(state_value integer,sea_province integer)
returns boolean language sql stable security definer set search_path='' as $function$
  select exists(select 1 from fauxlore.military_accessible_port(state_value,sea_province))
$function$;
revoke all on function fauxlore.military_port_accessible(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.military_fleet_at_port(state_value integer,sea_province integer,x_value double precision,y_value double precision)
returns boolean language sql stable security definer set search_path='' as $function$
  select exists(select 1 from fauxlore.military_accessible_port(state_value,sea_province) port
    where abs(port.x-x_value)<=0.01 and abs(port.y-y_value)<=0.01)
$function$;
revoke all on function fauxlore.military_fleet_at_port(integer,integer,double precision,double precision) from public,anon,authenticated;

-- Tighten movement start/cancel checks and snap every route destination to the actual accessible port point.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.military_movement_api(text,bigint,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='if formation_row.domain=''naval'' and not fauxlore.military_port_accessible(formation_row.state_id,formation_row.province_id) then';
  new_fragment:='if formation_row.domain=''naval'' and not fauxlore.military_fleet_at_port(formation_row.state_id,formation_row.province_id,formation_row.position_x,formation_row.position_y) then';
  if position(old_fragment in fn)=0 then raise exception 'Could not tighten naval cancel-at-port check'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='if formation_row.domain=''naval'' and not exists(select 1 from fauxlore.military_movement_orders where formation_id=formation_key)'||chr(10)||
    '     and not fauxlore.military_port_accessible(formation_row.state_id,formation_row.province_id) then';
  new_fragment:='if formation_row.domain=''naval'' and not exists(select 1 from fauxlore.military_movement_orders where formation_id=formation_key)'||chr(10)||
    '     and not fauxlore.military_fleet_at_port(formation_row.state_id,formation_row.province_id,formation_row.position_x,formation_row.position_y) then';
  if position(old_fragment in fn)=0 then raise exception 'Could not tighten naval movement start check'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='  previous_province:=formation_row.province_id;';
  new_fragment:='  if formation_row.domain=''naval'' then'||chr(10)||
    '    destination_id:=(route_value->(jsonb_array_length(route_value)-1)->>''province_id'')::integer;'||chr(10)||
    '    select x,y into x_value,y_value from fauxlore.military_accessible_port(formation_row.state_id,destination_id);'||chr(10)||
    '    if not found then raise sqlstate ''22023'' using message=''Маршрут флотилии должен завершаться в доступном порту''; end if;'||chr(10)||
    '    route_value:=jsonb_set(route_value,array[(jsonb_array_length(route_value)-1)::text],'||
    '      (route_value->(jsonb_array_length(route_value)-1))||jsonb_build_object(''x'',x_value,''y'',y_value),false);'||chr(10)||
    '  end if;'||chr(10)||old_fragment;
  if position(old_fragment in fn)=0 then raise exception 'Could not add exact port arrival snapping'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('public.military_map_api()'::regprocedure),chr(13),'');
  old_fragment:='''is_port'',case when f.domain=''naval'' then fauxlore.military_port_accessible(f.state_id,f.province_id) else false end,';
  new_fragment:='''is_port'',case when f.domain=''naval'' then fauxlore.military_fleet_at_port(f.state_id,f.province_id,f.position_x,f.position_y) else false end,';
  if position(old_fragment in fn)=0 then raise exception 'Could not change map port indicator to use actual coordinates'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

-- Repair stationary ships and not-yet-started routes created under the former province-only port check.
do $repair$
declare fleet record; start_port record; end_port record; route_value jsonb; last_index integer; destination_id integer;
begin
  for fleet in
    select f.id,f.state_id,f.province_id,f.position_x,f.position_y,o.route,o.next_index
    from fauxlore.military_formations f
    left join fauxlore.military_movement_orders o on o.formation_id=f.id
    where f.active and f.domain='naval'
  loop
    if fleet.route is null then
      select * into start_port from fauxlore.military_accessible_port(fleet.state_id,fleet.province_id);
      if found then
        update fauxlore.military_formations set position_x=start_port.x,position_y=start_port.y where id=fleet.id;
      end if;
      continue;
    end if;

    route_value:=fleet.route;
    last_index:=jsonb_array_length(route_value)-1;
    if fleet.next_index=1 then
      select * into start_port from fauxlore.military_accessible_port(fleet.state_id,fleet.province_id);
      if found then
        update fauxlore.military_formations set position_x=start_port.x,position_y=start_port.y where id=fleet.id;
        route_value:=jsonb_set(route_value,'{0}',(route_value->0)||jsonb_build_object('x',start_port.x,'y',start_port.y),false);
      end if;
    end if;
    destination_id:=nullif(route_value->last_index->>'province_id','')::integer;
    select * into end_port from fauxlore.military_accessible_port(fleet.state_id,destination_id);
    if found then
      route_value:=jsonb_set(route_value,array[last_index::text],(route_value->last_index)||
        jsonb_build_object('x',end_port.x,'y',end_port.y),false);
      update fauxlore.military_movement_orders set route=route_value where formation_id=fleet.id;
    end if;
  end loop;
end
$repair$;

select pg_notify('pgrst','reload schema');
