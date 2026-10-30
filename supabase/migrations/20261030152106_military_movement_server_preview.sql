-- Calculate the read-only route forecast from the same server weather, terrain
-- mask and road factors used when a movement order is resolved.
create or replace function fauxlore.military_movement_preview(formation_key bigint, route_value jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $function$
declare
  formation_row fauxlore.military_formations;
  province_row fauxlore.provinces;
  calendar_row fauxlore.game_calendar;
  point_a jsonb;
  point_b jsonb;
  index_value integer;
  maneuver_level integer;
  weather_value text;
  wind_degrees integer;
  heading_degrees numeric;
  wind_dot numeric;
  terrain_factor numeric;
  weather_factor numeric;
  road_factor numeric;
  segment_length numeric;
  budget numeric;
  total_distance numeric:=0;
  total_cost numeric:=0;
  sea_zones integer:=0;
  terrain_names text[]:='{}';
  weather_names text[]:='{}';
  terrain_name text;
begin
  select * into formation_row from fauxlore.military_formations where id=formation_key and active;
  select * into calendar_row from fauxlore.game_calendar where singleton=true;
  budget:=case when formation_row.domain='naval' then case when mod(calendar_row.turn,2)=1 then 2000 else 1200 end
    else case when mod(calendar_row.turn,2)=1 then 800 else 400 end end;
  select least(6,greatest(0,coalesce((leader.skills->>(case when formation_row.domain='naval' then 'Навигация' else 'Маневренность' end))::integer,0)))
    into maneuver_level from fauxlore.military_leaders leader where leader.id=formation_row.leader_id and leader.status='active';
  budget:=budget*(1+floor(coalesce(maneuver_level,0)/2)*.10);
  for index_value in 1..jsonb_array_length(route_value)-1 loop
    point_a:=route_value->(index_value-1);
    point_b:=route_value->index_value;
    select * into province_row from fauxlore.provinces where id=(point_b->>'province_id')::integer;
    segment_length:=sqrt(((point_b->>'x')::numeric-(point_a->>'x')::numeric)^2+
      ((point_b->>'y')::numeric-(point_a->>'y')::numeric)^2);
    if segment_length<.0001 then continue; end if;
    select weather,wind_degrees into weather_value,wind_degrees from fauxlore.province_weather
      where province_id=province_row.id and year=calendar_row.year and turn=calendar_row.turn;
    total_distance:=total_distance+segment_length;
    if formation_row.domain='naval' then
      terrain_factor:=case when fauxlore.military_open_sea(province_row.id) then 3 else 1 end;
      weather_factor:=case weather_value when 'storm' then 2 when 'snow' then 1.25
        when 'heavy_rain' then 1.3 when 'rain' then 1.1 else 1 end;
      if weather_value='wind' then
        heading_degrees:=degrees(atan2(((point_b->>'y')::numeric-(point_a->>'y')::numeric)::double precision,
          ((point_b->>'x')::numeric-(point_a->>'x')::numeric)::double precision));
        wind_dot:=cos(radians(heading_degrees-coalesce(wind_degrees,0)));
        weather_factor:=weather_factor*case when wind_dot>.5 then .8 when wind_dot<-.5 then 1.25 else 1 end;
      end if;
      road_factor:=1;
      if (point_b->>'province_id')::integer is distinct from (point_a->>'province_id')::integer then sea_zones:=sea_zones+1; end if;
    else
      terrain_factor:=(case province_row.terrain_type when 'forest' then 1.25 when 'marsh' then 2 else 1 end)*
        fauxlore.military_terrain_segment_factor((point_a->>'x')::double precision,(point_a->>'y')::double precision,
          (point_b->>'x')::double precision,(point_b->>'y')::double precision);
      weather_factor:=case weather_value when 'rain' then 1.2 when 'heavy_rain' then 1.5
        when 'mud' then 1.5 when 'snow' then 1.5 when 'thaw' then 1.2 when 'wind' then 1.05
        when 'heat' then 1.15 when 'storm' then 2 else 1 end;
      road_factor:=coalesce((point_b->>'road_factor')::numeric,1);
      terrain_name:=case province_row.terrain_type when 'forest' then 'лес' when 'marsh' then 'болото' else null end;
      if terrain_name is not null and not terrain_name=any(terrain_names) then terrain_names:=array_append(terrain_names,terrain_name); end if;
    end if;
    if weather_value is not null and not weather_value=any(weather_names) then weather_names:=array_append(weather_names,weather_value); end if;
    total_cost:=total_cost+segment_length*terrain_factor*weather_factor*road_factor;
  end loop;
  return jsonb_build_object('distanceKm',round(total_distance,2),'cost',round(total_cost,2),'budget',round(budget,2),
    'turns',greatest(1,ceil(total_cost/nullif(budget,0))::integer,case when formation_row.domain='naval' then ceil(sea_zones/12.0)::integer else 1 end),
    'terrains',to_jsonb(terrain_names),'weathers',to_jsonb(weather_names),'unknown',0,
    'ports',case when formation_row.domain='naval' then true else false end,
    'stop',case when total_cost>budget then jsonb_build_object('reason','Исчерпана дальность движения на этот ход') else null end);
end
$function$;
revoke all on function fauxlore.military_movement_preview(bigint,jsonb) from public,anon,authenticated;

do $migration$
declare
  definition text;
  guard_marker text := 'elsif action<>''set_order'' then';
  insert_marker text := 'insert into fauxlore.military_movement_orders(formation_id,state_id,route,next_index,segment_progress,issued_by,issued_year,issued_turn,stop_reason,resolved_year,resolved_turn)';
begin
  definition:=pg_get_functiondef('fauxlore.military_movement_api(text,bigint,jsonb)'::regprocedure);
  if position(guard_marker in definition)=0 or position(insert_marker in definition)=0 then
    raise exception 'Movement preview insertion points changed';
  end if;
  definition:=replace(definition,guard_marker,'elsif action not in (''set_order'',''preview'') then');
  definition:=replace(definition,insert_marker,
    'if action=''preview'' then return fauxlore.military_movement_preview(formation_key,route_value); end if;'||E'\n  '||insert_marker);
  execute definition;
end
$migration$;
