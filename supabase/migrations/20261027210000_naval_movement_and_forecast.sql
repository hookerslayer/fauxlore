-- Naval coordinate movement, route forecasts and actionable stop reasons.
alter table fauxlore.military_movement_orders
  add column if not exists stop_reason text,
  add column if not exists resolved_year integer,
  add column if not exists resolved_turn integer;
alter table fauxlore.province_weather
  add column if not exists wind_degrees smallint not null default 0
    check(wind_degrees between 0 and 359);
update fauxlore.province_weather set wind_degrees=floor(random()*360)::smallint;

create or replace function fauxlore.military_port_accessible(state_value integer,sea_province integer)
returns boolean language sql stable security definer set search_path='' as $function$
  select exists(
    select 1 from fauxlore.map_markers marker
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
  )
$function$;
revoke all on function fauxlore.military_port_accessible(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.military_open_sea(sea_province integer)
returns boolean language sql stable security definer set search_path='' as $function$
  select p.kind='sea' and not exists(
    select 1 from fauxlore.map_adjacency graph
    cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->p.id::text,'[]'::jsonb)) n(value)
    join fauxlore.provinces land on land.id=n.value::integer and land.kind='land'
    where graph.singleton
  ) from fauxlore.provinces p where p.id=sea_province
$function$;
revoke all on function fauxlore.military_open_sea(integer) from public,anon,authenticated;

create or replace function fauxlore.refresh_province_weather(year_value integer,turn_value integer)
returns void language plpgsql security definer set search_path='' as $function$
begin
  with regional_rolls as (
    select floor((p.center->>0)::numeric/500) cell_x,floor((p.center->>1)::numeric/500) cell_y,
      random()*100 regional_roll,random()*360 regional_wind
    from fauxlore.provinces p group by 1,2
  ), rolls as (
    select p.id,coalesce(c.name,'Умеренный') climate_name,
      regional_rolls.regional_roll*.75+random()*100*.25 roll_value,
      mod(round(regional_rolls.regional_wind+(random()*60-30)+360)::integer,360)::smallint wind_value
    from fauxlore.provinces p
    left join fauxlore.province_values pv on pv.province_id=p.id and pv.layer='climate'
    left join fauxlore.map_categories c on c.layer='climate' and c.id=pv.category_id
    join regional_rolls on regional_rolls.cell_x=floor((p.center->>0)::numeric/500)
      and regional_rolls.cell_y=floor((p.center->>1)::numeric/500)
  )
  insert into fauxlore.province_weather(province_id,weather,roll,year,turn,wind_degrees)
    select id,fauxlore.weather_for_climate(climate_name,mod(turn_value,2)=1,roll_value::numeric),
      roll_value,year_value,turn_value,wind_value from rolls
  on conflict(province_id) do update set weather=excluded.weather,roll=excluded.roll,year=excluded.year,
    turn=excluded.turn,wind_degrees=excluded.wind_degrees;
end
$function$;
revoke all on function fauxlore.refresh_province_weather(integer,integer) from public,anon,authenticated;
do $$ declare cal fauxlore.game_calendar; begin
  select * into cal from fauxlore.game_calendar where singleton=true;
  perform fauxlore.refresh_province_weather(cal.year,cal.turn);
end $$;

-- Newly created formations start at the geometric centre of their base province.
create or replace function fauxlore.set_military_formation_position()
returns trigger language plpgsql security definer set search_path='' as $function$
declare center_value jsonb;
begin
  if new.position_x is null or new.position_y is null then
    select center into center_value from fauxlore.provinces where id=new.province_id;
    if not found then raise sqlstate '22023' using message='Провинция формирования не найдена'; end if;
    new.position_x:=coalesce(new.position_x,(center_value->>0)::double precision);
    new.position_y:=coalesce(new.position_y,(center_value->>1)::double precision);
  end if;
  return new;
end
$function$;
revoke all on function fauxlore.set_military_formation_position() from public,anon,authenticated;
drop trigger if exists military_formations_set_position on fauxlore.military_formations;
create trigger military_formations_set_position before insert on fauxlore.military_formations
  for each row execute function fauxlore.set_military_formation_position();

create or replace function fauxlore.military_movement_api(action text,formation_key bigint,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; formation_row fauxlore.military_formations; current_calendar fauxlore.game_calendar;
  route_value jsonb:=payload->'route'; route_point jsonb; province_row fauxlore.provinces; previous_province integer;
  region_value jsonb; x_value numeric; y_value numeric; road_value numeric; owner_id integer; occupier_id integer; i integer;
  expected_kind text; destination_id integer; open_sea boolean;
begin
  actor:=fauxlore.current_account();
  select * into formation_row from fauxlore.military_formations where id=formation_key and active for update;
  if not found or formation_row.domain not in ('land','naval') then raise sqlstate '22023' using message='Формирование не найдено'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states where account_id=actor.id and state_id=formation_row.state_id) then
    raise sqlstate '42501' using message='Нет доступа к этому формированию';
  end if;
  if action='cancel' then
    if formation_row.domain='naval' and not fauxlore.military_port_accessible(formation_row.state_id,formation_row.province_id) then
      raise sqlstate '22023' using message='Флот в море: задайте курс до доступного порта, чтобы завершить плавание';
    end if;
    delete from fauxlore.military_movement_orders where military_movement_orders.formation_id=formation_key;
    return jsonb_build_object('cancelled',true,'formation_id',formation_key);
  elsif action<>'set_order' then raise sqlstate '22023' using message='Неизвестное действие движения'; end if;
  if jsonb_typeof(route_value) is distinct from 'array' or jsonb_array_length(route_value)<2 or jsonb_array_length(route_value)>5000 then
    raise sqlstate '22023' using message='Маршрут должен содержать от 2 до 5000 точек'; end if;
  select * into current_calendar from fauxlore.game_calendar where singleton=true;
  select value_json into region_value from fauxlore._settings where key='region';
  expected_kind:=case formation_row.domain when 'naval' then 'sea' else 'land' end;
  if formation_row.domain='naval' and not exists(select 1 from fauxlore.military_movement_orders where formation_id=formation_key)
     and not fauxlore.military_port_accessible(formation_row.state_id,formation_row.province_id) then
    raise sqlstate '22023' using message='Флотилия должна начинать плавание в доступном порту';
  end if;
  previous_province:=formation_row.province_id;
  for i in 0..jsonb_array_length(route_value)-1 loop
    route_point:=route_value->i;
    if jsonb_typeof(route_point) is distinct from 'object' or jsonb_typeof(route_point->'x') is distinct from 'number'
       or jsonb_typeof(route_point->'y') is distinct from 'number' or jsonb_typeof(route_point->'province_id') is distinct from 'number' then
      raise sqlstate '22023' using message='Некорректная точка маршрута'; end if;
    x_value:=(route_point->>'x')::numeric;y_value:=(route_point->>'y')::numeric;
    if x_value<(region_value->>0)::numeric or y_value<(region_value->>1)::numeric
       or x_value>=(region_value->>2)::numeric or y_value>=(region_value->>3)::numeric then
      raise sqlstate '22023' using message='Точка маршрута находится вне игровой области'; end if;
    select * into province_row from fauxlore.provinces where id=(route_point->>'province_id')::integer and kind=expected_kind;
    if not found or x_value<(province_row.bbox->>0)::numeric or x_value>=(province_row.bbox->>2)::numeric
       or y_value<(province_row.bbox->>1)::numeric or y_value>=(province_row.bbox->>3)::numeric then
      raise sqlstate '22023' using message=case formation_row.domain when 'naval' then 'Маршрут флотилии должен проходить по морю' else 'Координаты должны находиться внутри сухопутной провинции' end; end if;
    if i=0 then
      if province_row.id<>formation_row.province_id or abs(x_value-formation_row.position_x)>1 or abs(y_value-formation_row.position_y)>1 then
        raise sqlstate '22023' using message='Маршрут должен начинаться у текущего положения формирования'; end if;
    elsif previous_province<>province_row.id and not exists(
      select 1 from fauxlore.map_adjacency graph
      cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->previous_province::text,'[]'::jsonb)) neighbor(value)
      where graph.singleton and neighbor.value::integer=province_row.id) then
      raise sqlstate '22023' using message='Маршрут перескакивает через несоседнюю провинцию';
    end if;
    if formation_row.domain='land' then
      select pv.category_id into owner_id from fauxlore.province_values pv where pv.province_id=province_row.id and pv.layer='states';
      select c.id into occupier_id from fauxlore.map_categories c where c.layer='states' and lower(c.name)=lower(province_row.occupation);
      if coalesce(occupier_id,owner_id) is not null and coalesce(occupier_id,owner_id)<>formation_row.state_id
         and not exists(select 1 from fauxlore.military_wars w where w.active and
           ((w.attacker_id=formation_row.state_id and w.defender_id=coalesce(occupier_id,owner_id)) or
            (w.defender_id=formation_row.state_id and w.attacker_id=coalesce(occupier_id,owner_id))))
         and not exists(select 1 from fauxlore.military_diplomacy d where d.kind='passage' and d.status='accepted' and
           ((d.from_state_id=formation_row.state_id and d.to_state_id=coalesce(occupier_id,owner_id)) or
            (d.to_state_id=formation_row.state_id and d.from_state_id=coalesce(occupier_id,owner_id)))) then
        raise sqlstate '42501' using message='Нет права прохода через провинцию «'||province_row.name||'»';
      end if;
      road_value:=fauxlore.military_road_factor(x_value::double precision,y_value::double precision);
      if province_row.terrain_type='high_mountains' and road_value>=1 then raise sqlstate '22023' using message='Маршрут пересекает непроходимые высокие горы без перевала'; end if;
    else
      open_sea:=fauxlore.military_open_sea(province_row.id);
      if open_sea and exists(select 1 from fauxlore.military_formation_units fu
        join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=formation_key and u.name='Галера' and fu.quantity>0) then
        raise sqlstate '22023' using message='Галера не может пересекать открытое море';
      end if;
      road_value:=1;
    end if;
    route_value:=jsonb_set(route_value,array[i::text],route_point||jsonb_build_object('road_factor',road_value));
    previous_province:=province_row.id;
  end loop;
  if route_value->0->>'province_id'<>formation_row.province_id::text then raise sqlstate '22023' using message='Начальная провинция маршрута изменилась'; end if;
  if formation_row.domain='naval' then
    destination_id:=(route_value->(jsonb_array_length(route_value)-1)->>'province_id')::integer;
    if not fauxlore.military_port_accessible(formation_row.state_id,destination_id) then
      raise sqlstate '22023' using message='Маршрут флотилии должен завершаться в порту с правом базирования';
    end if;
  end if;
  insert into fauxlore.military_movement_orders(formation_id,state_id,route,next_index,segment_progress,issued_by,issued_year,issued_turn,stop_reason,resolved_year,resolved_turn)
    values(formation_key,formation_row.state_id,route_value,1,0,actor.id,current_calendar.year,current_calendar.turn,null,null,null)
  on conflict(formation_id) do update set state_id=excluded.state_id,route=excluded.route,next_index=1,segment_progress=0,
    issued_by=excluded.issued_by,issued_year=excluded.issued_year,issued_turn=excluded.issued_turn,stop_reason=null,resolved_year=null,resolved_turn=null,created_at=now();
  return jsonb_build_object('formation_id',formation_key,'route_points',jsonb_array_length(route_value),'issued_year',current_calendar.year,'issued_turn',current_calendar.turn);
end
$function$;
revoke all on function fauxlore.military_movement_api(text,bigint,jsonb) from public,anon;
grant execute on function fauxlore.military_movement_api(text,bigint,jsonb) to authenticated;

create or replace function fauxlore.resolve_military_movement(year_value integer,turn_value integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare order_row fauxlore.military_movement_orders; formation_row fauxlore.military_formations; point_value jsonb; province_row fauxlore.provinces;
  idx integer; count_points integer; budget numeric; base_budget numeric; terrain_factor numeric; weather_factor numeric; road_factor numeric;
  segment_length numeric; remaining_length numeric; segment_cost numeric; fraction_value numeric; start_x numeric; start_y numeric; end_x numeric; end_y numeric;
  moved_count integer:=0; maneuver_level integer; weather_value text; wind_degrees integer; heading_degrees numeric; wind_dot numeric;
  sea_zones integer; stop_reason_value text; open_sea boolean;
begin
  base_budget:=case when mod(turn_value,2)=1 then 800 else 400 end;
  for order_row in select * from fauxlore.military_movement_orders order by formation_id for update loop
    select * into formation_row from fauxlore.military_formations where id=order_row.formation_id and active for update;
    if not found then delete from fauxlore.military_movement_orders where formation_id=order_row.formation_id; continue; end if;
    budget:=case when formation_row.domain='naval' then case when mod(turn_value,2)=1 then 2000 else 1200 end else base_budget end;
    select least(6,greatest(0,coalesce((l.skills->>(case when formation_row.domain='naval' then 'Навигация' else 'Маневренность' end))::integer,0))) into maneuver_level
      from fauxlore.military_leaders l where l.id=formation_row.leader_id and l.status='active';
    budget:=budget*(1+floor(coalesce(maneuver_level,0)/2)*.10);
    idx:=order_row.next_index;count_points:=jsonb_array_length(order_row.route);sea_zones:=0;stop_reason_value:=null;
    while idx<count_points and budget>0 loop
      point_value:=order_row.route->idx;
      end_x:=(point_value->>'x')::numeric;end_y:=(point_value->>'y')::numeric;
      start_x:=formation_row.position_x;start_y:=formation_row.position_y;
      select * into province_row from fauxlore.provinces where id=(point_value->>'province_id')::integer;
      if formation_row.domain='naval' and province_row.id<>formation_row.province_id then
        if sea_zones>=12 then stop_reason_value:='За ход пройдено предельное число морских провинций (12)';exit; end if;
        sea_zones:=sea_zones+1;
      end if;
      segment_length:=sqrt((end_x-start_x)^2+(end_y-start_y)^2);
      if segment_length<.0001 then
        formation_row.position_x:=end_x;formation_row.position_y:=end_y;formation_row.province_id:=(point_value->>'province_id')::integer;idx:=idx+1;continue;
      end if;
      select w.weather,w.wind_degrees into weather_value,wind_degrees from fauxlore.province_weather w
        where w.province_id=province_row.id and w.year=year_value and w.turn=turn_value;
      if formation_row.domain='naval' then
        open_sea:=fauxlore.military_open_sea(province_row.id);
        terrain_factor:=case when open_sea then 3 else 1 end;road_factor:=1;
        heading_degrees:=degrees(atan2((end_y-start_y)::double precision,(end_x-start_x)::double precision));
        wind_dot:=cos(radians(heading_degrees-coalesce(wind_degrees,0)));
        weather_factor:=case weather_value when 'storm' then 2 when 'snow' then 1.25 when 'heavy_rain' then 1.3 when 'rain' then 1.1 else 1 end;
        if weather_value='wind' then weather_factor:=weather_factor*case when wind_dot>.5 then .8 when wind_dot<-.5 then 1.25 else 1 end; end if;
        if open_sea and exists(select 1 from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
          where fu.formation_id=formation_row.id and u.name='Галера' and fu.quantity>0) then stop_reason_value:='Галера не может идти по открытому морю';exit; end if;
      else
        terrain_factor:=case province_row.terrain_type when 'forest' then 1.25 when 'hills' then 1.5 when 'marsh' then 2 when 'mountains' then 2.5 when 'high_mountains' then 4 else 1 end;
        weather_factor:=case weather_value when 'rain' then 1.2 when 'heavy_rain' then 1.5 when 'mud' then 1.5 when 'snow' then 1.5 when 'thaw' then 1.2 when 'wind' then 1.05 when 'heat' then 1.15 when 'storm' then 2 else 1 end;
        road_factor:=coalesce((point_value->>'road_factor')::numeric,1);
      end if;
      weather_factor:=coalesce(weather_factor,1);remaining_length:=segment_length;
      segment_cost:=remaining_length*terrain_factor*weather_factor*road_factor;
      if formation_row.domain='land' and province_row.terrain_type='high_mountains' and road_factor>=1 then
        stop_reason_value:='Остановлено перед непроходимыми высокими горами без перевала';budget:=0;exit;
      end if;
      if segment_cost<=budget then
        budget:=budget-segment_cost;formation_row.position_x:=end_x;formation_row.position_y:=end_y;
        formation_row.province_id:=(point_value->>'province_id')::integer;order_row.segment_progress:=0;idx:=idx+1;
      else
        fraction_value:=budget/(terrain_factor*weather_factor*road_factor);
        formation_row.position_x:=start_x+(end_x-start_x)*(fraction_value/segment_length);
        formation_row.position_y:=start_y+(end_y-start_y)*(fraction_value/segment_length);
        order_row.segment_progress:=0;budget:=0;
        stop_reason_value:='Исчерпана дальность движения на этот ход';
      end if;
    end loop;
    if idx<count_points and stop_reason_value is null and budget<=0 then stop_reason_value:='Исчерпана дальность движения на этот ход'; end if;
    update fauxlore.military_formations set province_id=formation_row.province_id,position_x=formation_row.position_x,position_y=formation_row.position_y where id=formation_row.id;
    if idx>=count_points then delete from fauxlore.military_movement_orders where formation_id=order_row.formation_id;
    else update fauxlore.military_movement_orders set next_index=idx,segment_progress=order_row.segment_progress,
      stop_reason=coalesce(stop_reason_value,'Маршрут продолжится в следующем ходу'),resolved_year=year_value,resolved_turn=turn_value
      where formation_id=order_row.formation_id; end if;
    moved_count:=moved_count+1;
  end loop;
  return moved_count;
end
$function$;
revoke all on function fauxlore.resolve_military_movement(integer,integer) from public,anon,authenticated;

-- Return forecast conditions only for provinces inside the existing military fog of war.
do $$ declare fn text; old_fragment text; new_fragment text; begin
  fn:=replace(pg_get_functiondef('public.military_map_api()'::regprocedure),chr(13),'');
  old_fragment:='''movement_order'',(select jsonb_build_object(''route'',mo.route,''next_index'',mo.next_index,''segment_progress'',mo.segment_progress) from fauxlore.military_movement_orders mo where mo.formation_id=f.id),';
  new_fragment:='''movement_order'',(select jsonb_build_object(''route'',mo.route,''next_index'',mo.next_index,''segment_progress'',mo.segment_progress,''stop_reason'',mo.stop_reason,''resolved_year'',mo.resolved_year,''resolved_turn'',mo.resolved_turn) from fauxlore.military_movement_orders mo where mo.formation_id=f.id),';
  if position(old_fragment in fn)=0 then raise exception 'Could not extend movement order map payload'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='''leader_name'',leader.name,''units'',coalesce(';
  new_fragment:='''leader_name'',leader.name,''maneuver_level'',coalesce((leader.skills->>(case when f.domain=''naval'' then ''Навигация'' else ''Маневренность'' end))::integer,0),''is_port'',case when f.domain=''naval'' then fauxlore.military_port_accessible(f.state_id,f.province_id) else false end,''units'',coalesce(';
  if position(old_fragment in fn)=0 then raise exception 'Could not add movement skills and port state to map payload'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='''fog_of_war'',not all_visible';
  new_fragment:='''calendar'',(select jsonb_build_object(''year'',year,''turn'',turn) from fauxlore.game_calendar where singleton),''movement_conditions'',(select coalesce(jsonb_object_agg(p.id::text,jsonb_build_object(''name'',p.name,''kind'',p.kind,''terrain_type'',p.terrain_type,''weather'',w.weather,''wind_degrees'',w.wind_degrees,''open_sea'',case when p.kind=''sea'' then fauxlore.military_open_sea(p.id) else false end,''has_port'',exists(select 1 from fauxlore.map_markers marker where marker.type=''port'' and marker.province_id=p.id))),''{}''::jsonb) from fauxlore.provinces p left join fauxlore.province_weather w on w.province_id=p.id where all_visible or p.id=any(visible_provinces)),''fog_of_war'',not all_visible';
  if position(old_fragment in fn)=0 then raise exception 'Could not add movement forecast map payload'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;

select pg_notify('pgrst','reload schema');
