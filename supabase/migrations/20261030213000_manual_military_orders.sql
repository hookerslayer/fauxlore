-- Military movement is a player request reviewed by an administrator.
create table if not exists fauxlore.military_orders (
  id bigint generated always as identity primary key,
  formation_id bigint not null references fauxlore.military_formations(id) on delete cascade,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  route integer[] not null,
  destination_x double precision not null,
  destination_y double precision not null,
  travel_cost integer not null,
  status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
  issued_by bigint not null references fauxlore.accounts(id),
  reviewed_by bigint references fauxlore.accounts(id),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create unique index if not exists military_one_pending_order on fauxlore.military_orders(formation_id) where status='pending';
alter table fauxlore.military_orders enable row level security;
revoke all on fauxlore.military_orders from public,anon,authenticated;

create or replace function fauxlore.military_order_api(action text, formation_key bigint default null, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; formation_row fauxlore.military_formations; order_row fauxlore.military_orders;
  route_ids integer[]; route_id integer; previous_id integer; target_row fauxlore.provinces;
  cost integer:=0; limit_value integer; modifier_value integer:=0; destination_id integer;
  destination_x double precision; destination_y double precision; has_galley boolean;
  port_row record; unit_row record; new_quantity integer; source_row fauxlore.military_formations;
begin
  actor:=fauxlore.current_account();
  if actor.id is null then raise sqlstate '42501' using message='Требуется вход'; end if;
  if action='snapshot' then
    return jsonb_build_object('orders',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'formation_id',o.formation_id,'formation_name',f.name,'state_id',o.state_id,
      'route',o.route,'destination_x',o.destination_x,'destination_y',o.destination_y,
      'travel_cost',o.travel_cost,'status',o.status,'created_at',o.created_at) order by o.created_at desc)
      from fauxlore.military_orders o join fauxlore.military_formations f on f.id=o.formation_id
      where o.status='pending' and (actor.role='admin' or exists(select 1 from fauxlore.account_states s
        where s.account_id=actor.id and s.state_id=o.state_id))),'[]'::jsonb));
  end if;
  if action in ('approve','reject','cancel') then
    select * into order_row from fauxlore.military_orders where id=(payload->>'order_id')::bigint and status='pending' for update;
    if not found then raise sqlstate '22023' using message='Приказ уже рассмотрен или не найден'; end if;
    if action in ('approve','reject') and actor.role<>'admin' then raise sqlstate '42501' using message='Решение принимает администратор'; end if;
    if action='cancel' and actor.role<>'admin' and not exists(select 1 from fauxlore.account_states s where s.account_id=actor.id and s.state_id=order_row.state_id) then
      raise sqlstate '42501' using message='Нет доступа к приказу'; end if;
    if action='approve' then
      select * into formation_row from fauxlore.military_formations where id=order_row.formation_id and active for update;
      if not found or formation_row.province_id<>order_row.route[1] then raise sqlstate '22023' using message='Формирование изменило местоположение; создайте новый приказ'; end if;
      update fauxlore.military_formations set province_id=order_row.route[array_length(order_row.route,1)],position_x=order_row.destination_x,position_y=order_row.destination_y where id=formation_row.id;
    end if;
    update fauxlore.military_orders set status=case action when 'approve' then 'approved' when 'reject' then 'rejected' else 'cancelled' end,
      reviewed_by=actor.id,reviewed_at=now() where id=order_row.id;
    insert into fauxlore.notifications(account_id,kind,title,message)
      select s.account_id,'military_order','Приказ о передвижении',
        case action when 'approve' then 'Приказ подтверждён: формирование перемещено.' when 'reject' then 'Приказ отклонён администратором.' else 'Приказ отменён.' end
      from fauxlore.account_states s where s.state_id=order_row.state_id;
    return jsonb_build_object('id',order_row.id,'status',action);
  end if;
  select * into formation_row from fauxlore.military_formations where id=formation_key and active for update;
  if not found then raise sqlstate '22023' using message='Формирование не найдено'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states s where s.account_id=actor.id and s.state_id=formation_row.state_id) then
    raise sqlstate '42501' using message='Нет доступа к формированию'; end if;
  if action='place' or action='admin_move' then
    if action='admin_move' and actor.role<>'admin' then raise sqlstate '42501' using message='Только администратор может перемещать без приказа'; end if;
    destination_id:=case when action='place' then formation_row.province_id else (payload->>'province_id')::integer end;
    destination_x:=(payload->>'x')::double precision; destination_y:=(payload->>'y')::double precision;
    if fauxlore.military_province_mask_id(destination_x,destination_y) is distinct from destination_id then
      raise sqlstate '22023' using message='Точка должна находиться внутри выбранной провинции'; end if;
    select * into target_row from fauxlore.provinces where id=destination_id;
    if (formation_row.domain='naval' and target_row.kind<>'sea') or (formation_row.domain='land' and target_row.kind<>'land') then
      raise sqlstate '22023' using message='Тип провинции не подходит формированию'; end if;
    update fauxlore.military_formations set province_id=destination_id,position_x=destination_x,position_y=destination_y where id=formation_key;
    return jsonb_build_object('province_id',destination_id,'x',destination_x,'y',destination_y);
  end if;
  if action='admin_units' then
    if actor.role<>'admin' then raise sqlstate '42501' using message='Только администратор меняет численность'; end if;
    if jsonb_typeof(payload->'units')<>'array' then raise sqlstate '22023' using message='Укажите части'; end if;
    for unit_row in select value from jsonb_array_elements(payload->'units') loop
      new_quantity:=(unit_row.value->>'quantity')::integer;
      if new_quantity<0 or new_quantity>1000000 or not exists(select 1 from fauxlore.military_unit_catalog u where u.id=(unit_row.value->>'unit_id')::bigint and (u.domain=formation_row.domain or u.domain='siege' and formation_row.domain='land')) then
        raise sqlstate '22023' using message='Некорректная часть или численность'; end if;
      if new_quantity=0 then delete from fauxlore.military_formation_units where formation_id=formation_key and unit_id=(unit_row.value->>'unit_id')::bigint;
      else insert into fauxlore.military_formation_units(formation_id,unit_id,quantity) values(formation_key,(unit_row.value->>'unit_id')::bigint,new_quantity)
        on conflict(formation_id,unit_id) do update set quantity=excluded.quantity; end if;
    end loop;
    return jsonb_build_object('formation_id',formation_key,'updated',true);
  end if;
  if action='merge' then
    select * into source_row from fauxlore.military_formations where id=(payload->>'source_id')::bigint and active for update;
    if not found or source_row.id=formation_row.id or source_row.state_id<>formation_row.state_id or source_row.domain<>formation_row.domain or source_row.province_id<>formation_row.province_id then
      raise sqlstate '22023' using message='Объединять можно формирования одного государства в одной провинции'; end if;
    insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
      select formation_row.id,u.unit_id,u.quantity from fauxlore.military_formation_units u where u.formation_id=source_row.id
      on conflict(formation_id,unit_id) do update set quantity=fauxlore.military_formation_units.quantity+excluded.quantity;
    update fauxlore.military_formations set active=false where id=source_row.id;
    return jsonb_build_object('formation_id',formation_key,'merged',source_row.id);
  end if;
  if action not in ('preview','submit') then raise sqlstate '22023' using message='Неизвестное действие'; end if;
  if jsonb_typeof(payload->'route')<>'array' or jsonb_array_length(payload->'route')<2 or jsonb_array_length(payload->'route')>100 then
    raise sqlstate '22023' using message='Укажите маршрут по провинциям'; end if;
  select array_agg(value::integer order by ordinality) into route_ids from jsonb_array_elements_text(payload->'route') with ordinality;
  if route_ids[1]<>formation_row.province_id then raise sqlstate '22023' using message='Маршрут должен начинаться в текущей провинции'; end if;
  select exists(select 1 from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
    where fu.formation_id=formation_key and lower(u.name) like 'галер%') into has_galley;
  previous_id:=route_ids[1];
  foreach route_id in array route_ids[2:array_length(route_ids,1)] loop
    select * into target_row from fauxlore.provinces where id=route_id;
    if not found or (formation_row.domain='land' and target_row.kind<>'land') or (formation_row.domain='naval' and target_row.kind<>'sea') then
      raise sqlstate '22023' using message='Маршрут содержит неподходящую провинцию'; end if;
    if not exists(select 1 from fauxlore.map_adjacency a cross join lateral jsonb_array_elements_text(coalesce(a.neighbors->previous_id::text,'[]'::jsonb)) n where a.singleton and n.value::integer=route_id) then
      raise sqlstate '22023' using message='Маршрут должен проходить по соседним провинциям'; end if;
    if formation_row.domain='land' then
      cost:=cost+case target_row.terrain_type when 'forest' then 2 when 'mountains' then 2 when 'high_mountains' then 4 when 'marsh' then 3 else 1 end;
    else
      if exists(select 1 from fauxlore.map_adjacency a cross join lateral jsonb_array_elements_text(coalesce(a.neighbors->route_id::text,'[]'::jsonb)) n
        join fauxlore.provinces p on p.id=n.value::integer and p.kind='land' where a.singleton) then cost:=cost+1;
      else
        if has_galley then raise sqlstate '22023' using message='Галеры не могут выходить в открытое море'; end if;
        cost:=cost+2;
      end if;
    end if;
    previous_id:=route_id;
  end loop;
  destination_id:=route_ids[array_length(route_ids,1)];
  destination_x:=coalesce((payload->>'x')::double precision,(target_row.center->>0)::double precision);
  destination_y:=coalesce((payload->>'y')::double precision,(target_row.center->>1)::double precision);
  if fauxlore.military_province_mask_id(destination_x,destination_y) is distinct from destination_id then
    raise sqlstate '22023' using message='Конечная точка должна находиться внутри провинции'; end if;
  if formation_row.domain='naval' then
    if not fauxlore.military_port_accessible(formation_row.state_id,route_ids[1]) or not fauxlore.military_port_accessible(formation_row.state_id,destination_id) then
      raise sqlstate '22023' using message='Флот отправляется и прибывает только в доступный порт'; end if;
    if not exists(select 1 from fauxlore.map_markers m where m.type='port' and m.province_id=destination_id
      and abs(m.x-destination_x)<1 and abs(m.y-destination_y)<1) then
      raise sqlstate '22023' using message='Конечная точка флота должна совпадать с портом'; end if;
  end if;
  limit_value:=case when formation_row.domain='naval' then 15 else 10 end;
  -- Permanent and administrator modifiers are added once, as integer province costs.
  select coalesce(sum(trunc((m->>'value')::numeric)::integer),0) into modifier_value
    from jsonb_array_elements(fauxlore.state_permanent_modifiers(formation_row.state_id)) m
    where m->>'effect' = case when formation_row.domain='naval' then 'Лимит передвижения флота' else 'Лимит передвижения армии' end;
  limit_value:=greatest(0,limit_value+modifier_value);
  if cost>limit_value then raise sqlstate '22023' using message='Маршрут превышает лимит передвижения: '||cost||' из '||limit_value; end if;
  if action='preview' then return jsonb_build_object('cost',cost,'limit',limit_value,'destination_id',destination_id,'route',route_ids); end if;
  insert into fauxlore.military_orders(formation_id,state_id,route,destination_x,destination_y,travel_cost,issued_by)
    values(formation_key,formation_row.state_id,route_ids,destination_x,destination_y,cost,actor.id) returning * into order_row;
  insert into fauxlore.notifications(account_id,kind,title,message)
    select a.id,'military_order','Новый приказ о передвижении',formation_row.name||': '||array_to_string(route_ids,' → ')
    from fauxlore.accounts a where a.role='admin';
  return jsonb_build_object('id',order_row.id,'status','pending','cost',cost,'limit',limit_value);
end $function$;
revoke all on function fauxlore.military_order_api(text,bigint,jsonb) from public,anon,authenticated;
create or replace function public.military_order_api(action text, formation_key bigint default null, payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path='' as $function$
  select fauxlore.military_order_api(action,formation_key,payload)
$function$;
revoke all on function public.military_order_api(text,bigint,jsonb) from public,anon;
grant execute on function public.military_order_api(text,bigint,jsonb) to authenticated;

-- Existing turn hooks may still call these functions. They no longer move troops or
-- create battles, attrition, siege phases, or assaults.
create or replace function fauxlore.resolve_military_movement(year_value integer,turn_value integer) returns integer language plpgsql security definer set search_path='' as $$ begin return 0; end $$;
create or replace function fauxlore.resolve_military_encounters(year_value integer,turn_value integer) returns integer language plpgsql security definer set search_path='' as $$ begin return 0; end $$;
create or replace function fauxlore.resolve_military_sieges(year_value integer,turn_value integer) returns integer language plpgsql security definer set search_path='' as $$ begin return 0; end $$;
create or replace function fauxlore.resolve_military_attrition(year_value integer,turn_value integer) returns integer language plpgsql security definer set search_path='' as $$ begin return 0; end $$;
revoke all on function fauxlore.resolve_military_movement(integer,integer),fauxlore.resolve_military_encounters(integer,integer),fauxlore.resolve_military_sieges(integer,integer),fauxlore.resolve_military_attrition(integer,integer) from public,anon,authenticated;
notify pgrst,'reload schema';

