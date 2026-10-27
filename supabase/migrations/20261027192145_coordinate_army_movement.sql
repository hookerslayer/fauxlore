-- Coordinate movement for land armies. Coordinates use the map's 1 px = 1 km scale.
alter table fauxlore.military_formations
  add column if not exists position_x double precision,
  add column if not exists position_y double precision;

update fauxlore.military_formations f
set position_x=(p.center->>0)::double precision,
    position_y=(p.center->>1)::double precision
from fauxlore.provinces p
where p.id=f.province_id and (f.position_x is null or f.position_y is null);

alter table fauxlore.military_formations
  alter column position_x set not null,
  alter column position_y set not null;

create table if not exists fauxlore.military_movement_orders (
  formation_id bigint primary key references fauxlore.military_formations(id) on delete cascade,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  route jsonb not null check(jsonb_typeof(route)='array' and jsonb_array_length(route) between 2 and 5000),
  next_index integer not null default 1 check(next_index>=1),
  segment_progress numeric(12,4) not null default 0 check(segment_progress>=0),
  issued_by bigint not null references fauxlore.accounts(id),
  issued_year integer not null,
  issued_turn integer not null,
  created_at timestamptz not null default now()
);
create index if not exists military_movement_state_idx on fauxlore.military_movement_orders(state_id,formation_id);
alter table fauxlore.military_movement_orders enable row level security;
revoke all on fauxlore.military_movement_orders from public,anon,authenticated;

create table if not exists fauxlore.province_weather (
  province_id integer primary key references fauxlore.provinces(id) on delete cascade,
  weather text not null,
  roll numeric(7,4) not null check(roll>=0 and roll<100),
  year integer not null,
  turn integer not null
);
alter table fauxlore.province_weather enable row level security;
revoke all on fauxlore.province_weather from public,anon,authenticated;

create or replace function fauxlore.weather_for_climate(climate_name text,warm_turn boolean,roll_value numeric)
returns text language plpgsql immutable set search_path='' as $function$
declare climate_value text:=lower(coalesce(climate_name,'умеренный'));
begin
  if climate_value like '%холод%' then
    if warm_turn then return case when roll_value<35 then 'clear' when roll_value<60 then 'rain' when roll_value<75 then 'fog' when roll_value<90 then 'wind' else 'calm' end;
    else return case when roll_value<40 then 'snow' when roll_value<60 then 'clear' when roll_value<75 then 'fog' when roll_value<90 then 'wind' else 'thaw' end; end if;
  elsif climate_value like '%троп%' then
    if warm_turn then return case when roll_value<25 then 'clear' when roll_value<60 then 'heavy_rain' when roll_value<75 then 'drought' when roll_value<80 then 'fog' when roll_value<90 then 'wind' else 'calm' end;
    else return case when roll_value<30 then 'clear' when roll_value<60 then 'heavy_rain' when roll_value<70 then 'drought' when roll_value<80 then 'fog' when roll_value<90 then 'wind' else 'calm' end; end if;
  elsif climate_value like '%пустын%' then
    if warm_turn then return case when roll_value<40 then 'clear' when roll_value<70 then 'heat' when roll_value<90 then 'drought' else 'wind' end;
    else return case when roll_value<55 then 'clear' when roll_value<70 then 'cold' when roll_value<85 then 'drought' else 'wind' end; end if;
  elsif warm_turn then
    return case when roll_value<30 then 'clear' when roll_value<50 then 'rain' when roll_value<60 then 'drought' when roll_value<70 then 'fog' when roll_value<80 then 'wind' when roll_value<90 then 'calm' else 'autumn' end;
  else
    return case when roll_value<25 then 'clear' when roll_value<40 then 'snow' when roll_value<60 then 'rain' when roll_value<80 then 'mud' when roll_value<90 then 'fog' else 'wind' end;
  end if;
end
$function$;
revoke all on function fauxlore.weather_for_climate(text,boolean,numeric) from public,anon,authenticated;

create or replace function fauxlore.refresh_province_weather(year_value integer,turn_value integer)
returns void language plpgsql security definer set search_path='' as $function$
begin
  with regional_rolls as (
    select floor((p.center->>0)::numeric/500) cell_x,floor((p.center->>1)::numeric/500) cell_y,random()*100 regional_roll
    from fauxlore.provinces p group by 1,2
  ), rolls as (
    select p.id,coalesce(c.name,'Умеренный') climate_name,
      regional_rolls.regional_roll*.75+random()*100*.25 roll_value
    from fauxlore.provinces p
    left join fauxlore.province_values pv on pv.province_id=p.id and pv.layer='climate'
    left join fauxlore.map_categories c on c.layer='climate' and c.id=pv.category_id
    join regional_rolls on regional_rolls.cell_x=floor((p.center->>0)::numeric/500)
      and regional_rolls.cell_y=floor((p.center->>1)::numeric/500)
  )
  insert into fauxlore.province_weather(province_id,weather,roll,year,turn)
    select id,fauxlore.weather_for_climate(climate_name,mod(turn_value,2)=1,roll_value::numeric),roll_value,year_value,turn_value from rolls
  on conflict(province_id) do update set weather=excluded.weather,roll=excluded.roll,year=excluded.year,turn=excluded.turn;
  return;
end
$function$;
revoke all on function fauxlore.refresh_province_weather(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.advance_weather_on_calendar() returns trigger
language plpgsql security definer set search_path='' as $function$
begin
  perform fauxlore.refresh_province_weather(new.year,new.turn);
  return new;
end
$function$;
revoke all on function fauxlore.advance_weather_on_calendar() from public,anon,authenticated;
drop trigger if exists zzzzzza_refresh_province_weather on fauxlore.game_calendar;
create trigger zzzzzza_refresh_province_weather after update of year,turn on fauxlore.game_calendar
for each row when (new.year is distinct from old.year or new.turn is distinct from old.turn)
execute function fauxlore.advance_weather_on_calendar();

create or replace function fauxlore.military_road_factor(x_value double precision,y_value double precision)
returns numeric language plpgsql stable security definer set search_path='' as $function$
declare road_row record; segment_value jsonb; i integer; ax double precision; ay double precision; bx double precision; by_value double precision;
  dx double precision; dy double precision; t double precision; distance_value double precision; best numeric:=1;
begin
  for road_row in select type,segments from fauxlore.map_roads loop
    for segment_value in select value from jsonb_array_elements(road_row.segments) loop
      if jsonb_array_length(segment_value)<2 then continue; end if;
      for i in 0..jsonb_array_length(segment_value)-2 loop
        ax:=(segment_value->i->>0)::double precision; ay:=(segment_value->i->>1)::double precision;
        bx:=(segment_value->(i+1)->>0)::double precision; by_value:=(segment_value->(i+1)->>1)::double precision;
        dx:=bx-ax; dy:=by_value-ay;
        if dx*dx+dy*dy=0 then t:=0; else t:=greatest(0,least(1,((x_value-ax)*dx+(y_value-ay)*dy)/(dx*dx+dy*dy))); end if;
        distance_value:=sqrt((x_value-(ax+t*dx))^2+(y_value-(ay+t*dy))^2);
        if distance_value<=3 then
          best:=least(best,case road_row.type when 'trail' then .90 when 'highway' then .80 else .70 end);
        end if;
      end loop;
    end loop;
  end loop;
  return best;
end
$function$;
revoke all on function fauxlore.military_road_factor(double precision,double precision) from public,anon,authenticated;

create or replace function fauxlore.military_movement_api(action text,formation_key bigint,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; formation_row fauxlore.military_formations; current_calendar fauxlore.game_calendar;
  route_value jsonb:=payload->'route'; route_point jsonb; province_row fauxlore.provinces; previous_province integer;
  region_value jsonb; x_value numeric; y_value numeric; road_value numeric; owner_id integer; occupier_id integer; i integer;
begin
  actor:=fauxlore.current_account();
  select * into formation_row from fauxlore.military_formations where id=formation_key and active for update;
  if not found or formation_row.domain<>'land' then raise sqlstate '22023' using message='Сухопутная армия не найдена'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states where account_id=actor.id and state_id=formation_row.state_id) then
    raise sqlstate '42501' using message='Нет доступа к этой армии';
  end if;
  if action='cancel' then
    delete from fauxlore.military_movement_orders where military_movement_orders.formation_id=formation_key;
    return jsonb_build_object('cancelled',true,'formation_id',formation_key);
  elsif action<>'set_order' then
    raise sqlstate '22023' using message='Неизвестное действие движения армии';
  end if;
  if jsonb_typeof(route_value) is distinct from 'array' or jsonb_array_length(route_value)<2 or jsonb_array_length(route_value)>5000 then
    raise sqlstate '22023' using message='Маршрут должен содержать от 2 до 5000 точек'; end if;
  select * into current_calendar from fauxlore.game_calendar where singleton=true;
  select value_json into region_value from fauxlore._settings where key='region';
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
    select * into province_row from fauxlore.provinces where id=(route_point->>'province_id')::integer and kind='land';
    if not found or x_value<(province_row.bbox->>0)::numeric or x_value>=(province_row.bbox->>2)::numeric
       or y_value<(province_row.bbox->>1)::numeric or y_value>=(province_row.bbox->>3)::numeric then
      raise sqlstate '22023' using message='Координаты должны находиться внутри сухопутной провинции'; end if;
    if i=0 then
      if province_row.id<>formation_row.province_id or abs(x_value-formation_row.position_x)>1 or abs(y_value-formation_row.position_y)>1 then
        raise sqlstate '22023' using message='Маршрут должен начинаться у текущего положения армии'; end if;
    elsif previous_province<>province_row.id and not exists(
      select 1 from fauxlore.map_adjacency graph
      cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->previous_province::text,'[]'::jsonb)) neighbor(value)
      where graph.singleton and neighbor.value::integer=province_row.id) then
      raise sqlstate '22023' using message='Маршрут перескакивает через соседнюю провинцию';
    end if;
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
    route_value:=jsonb_set(route_value,array[i::text],route_point||jsonb_build_object('road_factor',road_value));
    previous_province:=province_row.id;
  end loop;
  if route_value->0->>'province_id'<>formation_row.province_id::text then raise sqlstate '22023' using message='Начальная провинция маршрута изменилась'; end if;
  insert into fauxlore.military_movement_orders(formation_id,state_id,route,next_index,segment_progress,issued_by,issued_year,issued_turn)
    values(formation_key,formation_row.state_id,route_value,1,0,actor.id,current_calendar.year,current_calendar.turn)
  on conflict(formation_id) do update set state_id=excluded.state_id,route=excluded.route,next_index=1,segment_progress=0,
    issued_by=excluded.issued_by,issued_year=excluded.issued_year,issued_turn=excluded.issued_turn,created_at=now();
  return jsonb_build_object('formation_id',formation_key,'route_points',jsonb_array_length(route_value),'issued_year',current_calendar.year,'issued_turn',current_calendar.turn);
end
$function$;
revoke all on function fauxlore.military_movement_api(text,bigint,jsonb) from public,anon;
grant execute on function fauxlore.military_movement_api(text,bigint,jsonb) to authenticated;

create or replace function public.military_movement_api(action text,formation_key bigint,payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path='' as $function$
  select fauxlore.military_movement_api(action,formation_key,payload)
$function$;
revoke all on function public.military_movement_api(text,bigint,jsonb) from public,anon;
grant execute on function public.military_movement_api(text,bigint,jsonb) to authenticated;

create or replace function fauxlore.resolve_military_movement(year_value integer,turn_value integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare order_row fauxlore.military_movement_orders; formation_row fauxlore.military_formations; point_value jsonb; province_row fauxlore.provinces;
  idx integer; count_points integer; budget numeric; base_budget numeric; terrain_factor numeric; weather_factor numeric; road_factor numeric;
  segment_length numeric; remaining_length numeric; segment_cost numeric; fraction_value numeric; start_x numeric; start_y numeric; end_x numeric; end_y numeric;
  moved_count integer:=0; maneuver_level integer;
begin
  base_budget:=case when mod(turn_value,2)=1 then 800 else 400 end;
  for order_row in select * from fauxlore.military_movement_orders order by formation_id for update loop
    select * into formation_row from fauxlore.military_formations where id=order_row.formation_id and active for update;
    if not found then delete from fauxlore.military_movement_orders where formation_id=order_row.formation_id; continue; end if;
    budget:=base_budget;
    select least(6,greatest(0,coalesce((l.skills->>'Маневренность')::integer,0))) into maneuver_level
      from fauxlore.military_leaders l where l.id=formation_row.leader_id and l.status='active';
    budget:=budget*(1+floor(coalesce(maneuver_level,0)/2)*.10);
    idx:=order_row.next_index;count_points:=jsonb_array_length(order_row.route);
    while idx<count_points and budget>0 loop
      point_value:=order_row.route->idx;
      end_x:=(point_value->>'x')::numeric;end_y:=(point_value->>'y')::numeric;
      start_x:=formation_row.position_x;start_y:=formation_row.position_y;
      segment_length:=sqrt((end_x-start_x)^2+(end_y-start_y)^2);
      if segment_length<.0001 then
        formation_row.position_x:=end_x;formation_row.position_y:=end_y;formation_row.province_id:=(point_value->>'province_id')::integer;idx:=idx+1;continue;
      end if;
      select * into province_row from fauxlore.provinces where id=(point_value->>'province_id')::integer;
      terrain_factor:=case province_row.terrain_type when 'forest' then 1.25 when 'hills' then 1.5 when 'marsh' then 2 when 'mountains' then 2.5 when 'high_mountains' then 4 else 1 end;
      select case weather when 'rain' then 1.2 when 'heavy_rain' then 1.5 when 'mud' then 1.5 when 'snow' then 1.5 when 'thaw' then 1.2 when 'wind' then 1.05 when 'heat' then 1.15 when 'storm' then 2 else 1 end
        into weather_factor from fauxlore.province_weather where province_id=province_row.id and year=year_value and turn=turn_value;
      weather_factor:=coalesce(weather_factor,1);
      road_factor:=coalesce((point_value->>'road_factor')::numeric,1);
      remaining_length:=segment_length;
      segment_cost:=remaining_length*terrain_factor*weather_factor*road_factor;
      if province_row.terrain_type='high_mountains' and road_factor>=1 then budget:=0;exit; end if;
      if segment_cost<=budget then
        budget:=budget-segment_cost;formation_row.position_x:=end_x;formation_row.position_y:=end_y;
        formation_row.province_id:=(point_value->>'province_id')::integer;order_row.segment_progress:=0;idx:=idx+1;
      else
        fraction_value:=budget/(terrain_factor*weather_factor*road_factor);
        formation_row.position_x:=start_x+(end_x-start_x)*(fraction_value/segment_length);
        formation_row.position_y:=start_y+(end_y-start_y)*(fraction_value/segment_length);
        order_row.segment_progress:=0;budget:=0;
      end if;
    end loop;
    update fauxlore.military_formations set province_id=formation_row.province_id,position_x=formation_row.position_x,position_y=formation_row.position_y where id=formation_row.id;
    if idx>=count_points then delete from fauxlore.military_movement_orders where formation_id=order_row.formation_id;
    else update fauxlore.military_movement_orders set next_index=idx,segment_progress=order_row.segment_progress where formation_id=order_row.formation_id; end if;
    moved_count:=moved_count+1;
  end loop;
  return moved_count;
end
$function$;
revoke all on function fauxlore.resolve_military_movement(integer,integer) from public,anon,authenticated;

-- Create initial weather state for the active year and turn.
do $$ declare cal fauxlore.game_calendar; begin select * into cal from fauxlore.game_calendar where singleton=true; perform fauxlore.refresh_province_weather(cal.year,cal.turn); end $$;

-- Add the movement phase before the established economic phase inside the atomic turn.
do $$ declare fn text; marker text; replacement text; begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  marker:='select config into cfg from fauxlore.economy_parameters where singleton=true for share;';
  replacement:=marker||E'\n  perform fauxlore.resolve_military_movement(calendar_row.year,calendar_row.turn);';
  if position(marker in fn)=0 then raise exception 'Military movement phase insertion point missing from turn_api'; end if;
  execute replace(fn,marker,replacement);
end $$;

-- Publish the army's exact coordinate and current route only inside the existing fog-of-war result.
do $$ declare fn text; old_fragment text; new_fragment text; begin
  fn:=replace(pg_get_functiondef('public.military_map_api()'::regprocedure),chr(13),'');
  old_fragment:='''province_name'',p.name,''x'',(p.center->>0)::numeric,''y'',(p.center->>1)::numeric,';
  new_fragment:='''province_name'',p.name,''x'',f.position_x,''y'',f.position_y,'||
    '''movement_order'',(select jsonb_build_object(''route'',mo.route,''next_index'',mo.next_index,''segment_progress'',mo.segment_progress) from fauxlore.military_movement_orders mo where mo.formation_id=f.id),';
  if position(old_fragment in fn)=0 then raise exception 'Military map coordinate insertion point missing'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;

-- Coordinate and queued-movement state must be included in the administrator's reversible test turn.
do $$ declare fn text; old_fragment text; new_fragment text; begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure),chr(13),'');
  old_fragment:='''game_calendar'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.game_calendar x)';
  new_fragment:=old_fragment||','||E'\n    '||'''military_formations'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.military_formations x),'||E'\n    '||
    '''military_movement_orders'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.military_movement_orders x),'||E'\n    '||
    '''province_weather'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.province_weather x)';
  if position(old_fragment in fn)=0 then raise exception 'Test-turn snapshot payload extension point missing'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;

do $$ declare fn text; old_fragment text; new_fragment text; begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:='''game_calendar'',(select coalesce(jsonb_agg(to_jsonb(x),''[]'') from fauxlore.game_calendar x)';
  -- The capture query uses a different aggregate shape from turn_snapshot_payload; match the exact checked-in expression.
  old_fragment:='''game_calendar'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.game_calendar x)';
  if position(old_fragment in fn)=0 then raise exception 'Test-turn before-payload extension point missing'; end if;
  new_fragment:=old_fragment||','||E'\n      '||'''military_formations'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.military_formations x),'||E'\n      '||
    '''military_movement_orders'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.military_movement_orders x),'||E'\n      '||
    '''province_weather'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.province_weather x)';
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='fauxlore.state_budget_ledger,fauxlore.trade_settlements,fauxlore.trade_market_settlements,fauxlore.trade_interzone_settlements,fauxlore.turn_economy_reports,fauxlore.game_calendar in access exclusive mode;';
  new_fragment:='fauxlore.state_budget_ledger,fauxlore.trade_settlements,fauxlore.trade_market_settlements,fauxlore.trade_interzone_settlements,fauxlore.turn_economy_reports,fauxlore.game_calendar,'||
    'fauxlore.military_formations,fauxlore.military_movement_orders,fauxlore.province_weather in access exclusive mode;';
  if position(old_fragment in fn)=0 then raise exception 'Test-turn rollback lock extension point missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='delete from fauxlore.notifications where true; delete from fauxlore.state_birth_events where true;';
  new_fragment:='delete from fauxlore.military_movement_orders where true; delete from fauxlore.province_weather where true;'||E'\n    '||old_fragment;
  if position(old_fragment in fn)=0 then raise exception 'Test-turn rollback delete extension point missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='''game_calendar'']) loop execute format(''alter table fauxlore.%I disable trigger user'',t);';
  new_fragment:='''game_calendar'',''military_formations'',''military_movement_orders'',''province_weather'']) loop execute format(''alter table fauxlore.%I disable trigger user'',t);';
  if position(old_fragment in fn)=0 then raise exception 'Test-turn trigger-suppression extension point missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='''game_calendar'']) loop execute format(''alter table fauxlore.%I enable trigger user'',t);';
  new_fragment:='''game_calendar'',''military_formations'',''military_movement_orders'',''province_weather'']) loop execute format(''alter table fauxlore.%I enable trigger user'',t);';
  if position(old_fragment in fn)=0 then raise exception 'Test-turn trigger-restoration extension point missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='if t=''state_profiles'' or t=''game_calendar'' then';
  new_fragment:='if t=''military_formations'' then'||E'\n        '||
    'execute format(''update fauxlore.%1$I target set province_id=saved.province_id,position_x=saved.position_x,position_y=saved.position_y from jsonb_populate_recordset(null::fauxlore.%1$I,$1) saved where target.id=saved.id'',t) using snap_row;'||E'\n      '||
    'elsif t=''state_profiles'' or t=''game_calendar'' then';
  if position(old_fragment in fn)=0 then raise exception 'Test-turn formation restore extension point missing'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;

create trigger military_movement_orders_live_revision after insert or update or delete on fauxlore.military_movement_orders
  for each statement execute function fauxlore.bump_live_revision();
create trigger province_weather_live_revision after insert or update or delete on fauxlore.province_weather
  for each statement execute function fauxlore.bump_live_revision();

-- Weather is prepared for the next calendar state; movement resolves before taxation at the start of each turn.
select pg_notify('pgrst','reload schema');
