-- Embark land formations on friendly fleets and disembark them at friendly coasts.
alter table fauxlore.military_formations
  add column if not exists transported_by bigint references fauxlore.military_formations(id) on delete set null;
create index if not exists military_formations_transported_by_idx
  on fauxlore.military_formations(transported_by) where transported_by is not null;

create or replace function fauxlore.sync_transported_armies()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if new.domain='naval' and new.active and
     (new.province_id is distinct from old.province_id or new.position_x is distinct from old.position_x or new.position_y is distinct from old.position_y) then
    update fauxlore.military_formations set province_id=new.province_id,position_x=new.position_x,position_y=new.position_y
      where transported_by=new.id and active;
  end if;
  return new;
end
$function$;
revoke all on function fauxlore.sync_transported_armies() from public,anon,authenticated;
drop trigger if exists military_sync_transported_armies on fauxlore.military_formations;
create trigger military_sync_transported_armies after update of province_id,position_x,position_y on fauxlore.military_formations
  for each row execute function fauxlore.sync_transported_armies();

create or replace function public.military_transport_api(action text,army_key bigint,fleet_key bigint,target_province integer default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; army fauxlore.military_formations; fleet fauxlore.military_formations;
  land_row fauxlore.provinces; sea_row fauxlore.provinces; target_row fauxlore.provinces;
  required_capacity bigint; available_capacity bigint; adjacent boolean; owner_key integer; occupier_key integer;
begin
  actor:=fauxlore.current_account();
  if action not in ('embark','disembark') then raise sqlstate '22023' using message='Неизвестное действие перевозки'; end if;
  perform 1 from fauxlore.military_formations where id in (army_key,fleet_key) order by id for update;
  select * into army from fauxlore.military_formations where id=army_key and active and domain='land' for update;
  select * into fleet from fauxlore.military_formations where id=fleet_key and active and domain='naval' for update;
  if not found or army.id is null or fleet.id is null then raise sqlstate '22023' using message='Армия или флотилия не найдены'; end if;
  if army.state_id<>fleet.state_id then raise sqlstate '42501' using message='Армия и флотилия должны принадлежать одному государству'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states where account_id=actor.id and state_id=army.state_id) then
    raise sqlstate '42501' using message='Нет доступа к этим формированиям';
  end if;
  if exists(select 1 from fauxlore.military_battles b where b.status='pending' and b.participants @>
    jsonb_build_array(jsonb_build_object('formation_id',army.id))) or
     exists(select 1 from fauxlore.military_battles b where b.status='pending' and b.participants @>
    jsonb_build_array(jsonb_build_object('formation_id',fleet.id))) then
    raise sqlstate '55000' using message='Нельзя менять перевозку во время незавершённого сражения';
  end if;
  if exists(select 1 from fauxlore.colonization_missions where status='active' and fleet_id=fleet.id) then
    raise sqlstate '55000' using message='Флотилия занята колонизационной миссией';
  end if;
  if exists(select 1 from fauxlore.military_movement_orders where formation_id in (army.id,fleet.id)) then
    raise sqlstate '55000' using message='Сначала завершите или отмените приказы движения армии и флота';
  end if;
  select * into sea_row from fauxlore.provinces where id=fleet.province_id and kind='sea';
  if not found then raise sqlstate '22023' using message='Флотилия должна находиться в морской провинции'; end if;
  if action='embark' then
    if army.transported_by is not null then raise sqlstate '22023' using message='Армия уже погружена на флот'; end if;
    select * into land_row from fauxlore.provinces where id=army.province_id and kind='land';
    if not found then raise sqlstate '22023' using message='Армия должна находиться на суше'; end if;
    select exists(select 1 from fauxlore.map_adjacency a
      cross join lateral jsonb_array_elements_text(coalesce(a.neighbors->sea_row.id::text,'[]'::jsonb)) n(value)
      where a.singleton and n.value::integer=land_row.id) into adjacent;
    if not adjacent or not fauxlore.military_port_accessible(fleet.state_id,sea_row.id) then
      raise sqlstate '22023' using message='Погрузка доступна только в порту рядом с армией';
    end if;
    select pv.category_id into owner_key from fauxlore.province_values pv where pv.province_id=land_row.id and pv.layer='states';
    select c.id into occupier_key from fauxlore.map_categories c where c.layer='states' and lower(c.name)=lower(land_row.occupation);
    if coalesce(occupier_key,owner_key)<>army.state_id or coalesce(land_row.control,100)<100 then
      raise sqlstate '42501' using message='Армия должна находиться в полностью контролируемой дружественной провинции';
    end if;
    select coalesce(sum(fu.quantity::bigint*u.recruit_cost),0) into required_capacity
      from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where fu.formation_id=army.id and u.domain in ('land','siege');
    select coalesce(sum(fu.quantity::bigint*u.capacity),0)*100 into available_capacity
      from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where fu.formation_id=fleet.id and u.domain='naval';
    select coalesce(sum(passenger.quantity::bigint*unit.recruit_cost),0) into available_capacity
      from fauxlore.military_formations onboard
      join fauxlore.military_formation_units passenger on passenger.formation_id=onboard.id
      join fauxlore.military_unit_catalog unit on unit.id=passenger.unit_id
      where onboard.transported_by=fleet.id and unit.domain in ('land','siege');
    -- The catalog's ship capacity is measured in hundreds of recruit points.
    if required_capacity+available_capacity>(select coalesce(sum(fu.quantity::bigint*u.capacity),0)*100
      from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where fu.formation_id=fleet.id and u.domain='naval') then
      raise sqlstate '22023' using message='Вместимости кораблей не хватает для этой армии';
    end if;
    update fauxlore.military_formations set transported_by=fleet.id,province_id=fleet.province_id,
      position_x=fleet.position_x,position_y=fleet.position_y where id=army.id;
    delete from fauxlore.military_movement_orders where formation_id=army.id;
    return jsonb_build_object('ok',true,'action',action,'army_id',army.id,'fleet_id',fleet.id,'capacity_used',required_capacity);
  end if;
  if army.transported_by is distinct from fleet.id then raise sqlstate '22023' using message='Эта армия не находится на выбранной флотилии'; end if;
  select * into target_row from fauxlore.provinces where id=target_province and kind='land';
  if not found then raise sqlstate '22023' using message='Выберите сухопутную провинцию для высадки'; end if;
  select exists(select 1 from fauxlore.map_adjacency a
    cross join lateral jsonb_array_elements_text(coalesce(a.neighbors->sea_row.id::text,'[]'::jsonb)) n(value)
    where a.singleton and n.value::integer=target_row.id) into adjacent;
  if not adjacent then raise sqlstate '22023' using message='Высадка возможна только на берегу рядом с флотилией'; end if;
  select pv.category_id into owner_key from fauxlore.province_values pv where pv.province_id=target_row.id and pv.layer='states';
  select c.id into occupier_key from fauxlore.map_categories c where c.layer='states' and lower(c.name)=lower(target_row.occupation);
  if coalesce(occupier_key,owner_key)<>army.state_id or coalesce(target_row.control,100)<100 then
    raise sqlstate '42501' using message='Высадка возможна только в полностью контролируемой дружественной провинции';
  end if;
  update fauxlore.military_formations set transported_by=null,province_id=target_row.id,
    position_x=(target_row.center->>0)::double precision,position_y=(target_row.center->>1)::double precision where id=army.id;
  return jsonb_build_object('ok',true,'action',action,'army_id',army.id,'fleet_id',fleet.id,'province_id',target_row.id);
end
$function$;
revoke all on function public.military_transport_api(text,bigint,bigint,integer) from public,anon;
grant execute on function public.military_transport_api(text,bigint,bigint,integer) to authenticated;

-- Carried armies neither move independently nor suffer field attrition or trigger land battles at sea.
do $migration$
declare fn text; marker text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.military_movement_api(text,bigint,jsonb)'::regprocedure),chr(13),'');
  marker:='if action=''cancel'' then';
  if position(marker in fn)=0 then raise exception 'Could not guard movement of embarked armies'; end if;
  fn:=replace(fn,marker,'if formation_row.transported_by is not null then raise sqlstate ''55000'' using message=''Погружённая армия перемещается вместе с флотом''; end if;'||chr(10)||'  '||marker);
  execute fn;

  fn:=replace(pg_get_functiondef('fauxlore.resolve_military_attrition(integer,integer)'::regprocedure),chr(13),'');
  marker:='where f.active and f.domain in (''land'',''naval'')';
  if position(marker in fn)=0 then raise exception 'Could not exclude embarked armies from attrition'; end if;
  execute replace(fn,marker,marker||' and f.transported_by is null');

  fn:=replace(pg_get_functiondef('fauxlore.resolve_military_encounters(integer,integer)'::regprocedure),chr(13),'');
  marker:='where f.active and f.domain in (''land'',''naval'') and exists(';
  if position(marker in fn)=0 then raise exception 'Could not exclude embarked armies from encounter search'; end if;
  fn:=replace(fn,marker,'where f.active and f.transported_by is null and f.domain in (''land'',''naval'') and exists(');
  marker:='where enemy.active and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id';
  if position(marker in fn)=0 then raise exception 'Could not exclude embarked armies from encounter matching'; end if;
  execute replace(fn,marker,'where enemy.active and enemy.transported_by is null and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id');

  fn:=replace(pg_get_functiondef('fauxlore.manage_formation_composition(text,integer,jsonb)'::regprocedure),chr(13),'');
  marker:='if source_row.domain=''naval'' and exists(select 1 from fauxlore.colonization_missions';
  if position(marker in fn)=0 then raise exception 'Could not protect transport capacity during formation split'; end if;
  fn:=replace(fn,marker,'if source_row.transported_by is not null or exists(select 1 from fauxlore.military_formations passenger where passenger.transported_by=source_key) then'||chr(10)||
    '     raise sqlstate ''55000'' using message=''Состав погружённой армии и её транспортной флотилии нельзя менять''; end if;'||chr(10)||'   '||marker);
  marker:='if source_row.domain<>target_row.domain then';
  if position(marker in fn)=0 then raise exception 'Could not protect transport capacity during formation transfer'; end if;
  fn:=replace(fn,marker,'if source_row.transported_by is not null or target_row.transported_by is not null or'||chr(10)||
    '      exists(select 1 from fauxlore.military_formations passenger where passenger.transported_by in (source_key,target_key)) then'||chr(10)||
    '     raise sqlstate ''55000'' using message=''Состав погружённой армии и её транспортной флотилии нельзя менять''; end if;'||chr(10)||'   '||marker);
  execute fn;
end
$migration$;

-- Naval defeat destroys the armies aboard losing fleets, as confirmed by the game owner.
do $migration$
declare fn text; marker text; replacement text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.military_battle_api(bigint,jsonb)'::regprocedure),chr(13),'');
  marker:='province_owner integer; province_name text; notification_text text;';
  replacement:=marker||chr(10)||'  passenger_row record; transported_losses jsonb:=''[]''::jsonb;';
  if position(marker in fn)=0 then raise exception 'Could not add embarked-army battle result state'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='  if battle_row.domain=''land'' then';
  replacement:='  if battle_row.domain=''naval'' then'||chr(10)||
    '    for passenger_row in select army.id,army.name,army.state_id,fleet.id fleet_id from jsonb_array_elements(battle_row.participants) part'||chr(10)||
    '      join fauxlore.military_formations fleet on fleet.id=(part->>''formation_id'')::bigint'||chr(10)||
    '      join fauxlore.military_formations army on army.transported_by=fleet.id and army.active'||chr(10)||
    '      where (part->>''state_id'')::integer<>winner_key for update of army loop'||chr(10)||
    '      delete from fauxlore.military_formation_units where formation_id=passenger_row.id;'||chr(10)||
    '      update fauxlore.military_formations set active=false,transported_by=null,leader_id=null where id=passenger_row.id;'||chr(10)||
    '      transported_losses:=transported_losses||jsonb_build_array(jsonb_build_object(''formation_id'',passenger_row.id,''formation_name'',passenger_row.name,''state_id'',passenger_row.state_id,''fleet_id'',passenger_row.fleet_id));'||chr(10)||
    '    end loop;'||chr(10)||
    '  end if;'||chr(10)||marker;
  if position(marker in fn)=0 then raise exception 'Could not add passenger losses to naval battle resolution'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='''control_transferred'',battle_row.domain=''land'',''province_id'',battle_row.province_id)';
  replacement:='''control_transferred'',battle_row.domain=''land'',''province_id'',battle_row.province_id,''transported_armies_lost'',transported_losses)';
  if position(marker in fn)=0 then raise exception 'Could not expose embarked-army battle losses'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='  insert into fauxlore.notifications(account_id,kind,title,message)';
  if position(marker in fn)=0 then raise exception 'Could not add passenger losses to battle notifications'; end if;
  fn:=replace(fn,marker,'  if jsonb_array_length(transported_losses)>0 then notification_text:=notification_text||'' Погружённые армии проигравшего флота потеряны.''; end if;'||chr(10)||marker);
  old_fragment:='''losses'',losses_value,''retreats'',retreats_value,''control_transferred'',battle_row.domain=''land'');';
  new_fragment:='''losses'',losses_value,''retreats'',retreats_value,''control_transferred'',battle_row.domain=''land'',''transported_armies_lost'',transported_losses);';
  if position(old_fragment in fn)=0 then raise exception 'Could not add embarked-army losses to battle response'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  execute fn;
end
$migration$;

-- Include adjacency for server-validated embark/disembark controls and passenger identity on map tokens.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='''port'',exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type=''port''))';
  new_fragment:='''port'',exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type=''port''),''controlled'',coalesce((select c.id from fauxlore.map_categories c where c.layer=''states'' and lower(c.name)=lower(p.occupation)),pv.category_id)=sid and coalesce(p.control,100)=100,''neighbors'',coalesce((select g.neighbors->p.id::text from fauxlore.map_adjacency g where g.singleton),''[]''::jsonb))';
  if position(old_fragment in fn)=0 then raise exception 'Could not add province adjacency to military snapshot'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('public.military_map_api()'::regprocedure),chr(13),'');
  old_fragment:='''state_id'',f.state_id,''state_name'',state.name,''state_color'',state.color,';
  new_fragment:='''state_id'',f.state_id,''state_name'',state.name,''state_color'',state.color,''transported_by'',f.transported_by,';
  if position(old_fragment in fn)=0 then raise exception 'Could not add passenger identity to map snapshot'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

select pg_notify('pgrst','reload schema');
