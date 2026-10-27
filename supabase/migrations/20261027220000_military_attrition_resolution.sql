-- Automatic, deterministic field attrition after simultaneous movement and before battles/economy.
create or replace function fauxlore.resolve_military_attrition(year_value integer,turn_value integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare formation_row record; province_row fauxlore.provinces; weather_value text; controller_id integer;
  total_power numeric; formation_power numeric; combat_quantity integer; markitant_quantity integer;
  supply_factor numeric; terrain_factor numeric; supply_limit numeric; formation_supply numeric;
  base_rate numeric; weather_rate numeric; control_kind text; maneuver_level integer;
  loss_rate numeric; losses integer; allocated integer; remaining integer; applied integer;
  unit_row record; message_value text; loss_lines jsonb; resolved_count integer:=0;
begin
  create temporary table if not exists pg_temp.military_attrition_allocations(
    unit_id bigint primary key, quantity integer not null, base_losses integer not null, remainder numeric not null
  ) on commit drop;

  for formation_row in
    select f.id,f.state_id,f.name,f.domain,f.province_id,f.leader_id
    from fauxlore.military_formations f
    where f.active and f.domain in ('land','naval')
    order by f.id
    for update of f
  loop
    select * into province_row from fauxlore.provinces p where p.id=formation_row.province_id;
    if not found then continue; end if;

    select coalesce(sum(fu.quantity*u.power),0)::numeric,
      coalesce(sum(fu.quantity) filter(where u.domain in ('land','siege') and u.category<>'Логистика'),0)::integer,
      coalesce(sum(fu.quantity) filter(where u.name='Маркитант'),0)::integer
    into formation_power,combat_quantity,markitant_quantity
    from fauxlore.military_formation_units fu
    join fauxlore.military_unit_catalog u on u.id=fu.unit_id
    where fu.formation_id=formation_row.id;
    if formation_power<=0 then continue; end if;

    select w.weather into weather_value from fauxlore.province_weather w
      where w.province_id=province_row.id and w.year=year_value and w.turn=turn_value;

    if formation_row.domain='naval' then
      -- A fleet in a usable port avoids attrition. At sea the base is 1%;
      -- the established outside-port rule doubles it to 2% per turn.
      if fauxlore.military_port_accessible(formation_row.state_id,formation_row.province_id) then continue; end if;
      loss_rate:=2;
      combat_quantity:=coalesce((select sum(fu.quantity)::integer
        from fauxlore.military_formation_units fu
        join fauxlore.military_unit_catalog u on u.id=fu.unit_id and u.domain='naval'
        where fu.formation_id=formation_row.id),0);
      if combat_quantity<=0 then continue; end if;
      supply_limit:=0;
    else
      if province_row.kind<>'land' then continue; end if;
      select coalesce(sum(fu.quantity*u.power),0)::numeric into total_power
      from fauxlore.military_formations f
      join fauxlore.military_formation_units fu on fu.formation_id=f.id
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id and u.domain in ('land','siege')
      where f.active and f.domain='land' and f.province_id=province_row.id;
      if total_power<=0 then continue; end if;

      select coalesce(occupier.id,owner.id) into controller_id
      from (select 1) seed
      left join fauxlore.province_values pv on pv.province_id=province_row.id and pv.layer='states'
      left join fauxlore.map_categories owner on owner.layer='states' and owner.id=pv.category_id
      left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(province_row.occupation);

      if controller_id=formation_row.state_id then
        control_kind:='friendly';
      elsif exists(select 1 from fauxlore.military_wars w where w.active and
        ((w.attacker_id=formation_row.state_id and w.defender_id=controller_id) or
         (w.defender_id=formation_row.state_id and w.attacker_id=controller_id))) then
        control_kind:='hostile';
      else
        control_kind:='neutral';
      end if;

      terrain_factor:=case province_row.terrain_type when 'forest' then .8 when 'marsh' then .4
        when 'hills' then .6 when 'mountains' then .4 when 'high_mountains' then .2 else 1 end;
      supply_factor:=case weather_value when 'snow' then .5 when 'heavy_rain' then .8 when 'drought' then .65
        when 'mud' then .95 when 'autumn' then 1.3 when 'thaw' then 1.1 else 1 end;
      supply_limit:=floor(coalesce(province_row.development,0)*10*terrain_factor*supply_factor);
      if control_kind='hostile' then supply_limit:=floor(supply_limit*.75); end if;
      formation_supply:=floor(supply_limit*formation_power/total_power)+floor(markitant_quantity/50)*50;
      if formation_power<=formation_supply then continue; end if;

      base_rate:=case province_row.terrain_type when 'forest' then 2 when 'marsh' then 3
        when 'hills' then 2 when 'mountains' then 3 when 'high_mountains' then 5 else 1 end;
      if control_kind='hostile' then base_rate:=base_rate*2; end if;
      weather_rate:=case weather_value when 'snow' then 2 when 'heavy_rain' then 1
        when 'drought' then 2 when 'autumn' then -1 else 0 end;
      select least(6,greatest(0,coalesce((l.skills->>'Маневренность')::integer,0))) into maneuver_level
      from fauxlore.military_leaders l where l.id=formation_row.leader_id and l.status='active' and l.domain='land';
      loss_rate:=greatest(0,base_rate+weather_rate+case when control_kind='neutral' then 1 else 0 end-coalesce(maneuver_level,0));
    end if;

    losses:=least(combat_quantity,floor(combat_quantity*loss_rate/100)::integer);
    if losses<=0 then continue; end if;
    truncate pg_temp.military_attrition_allocations;
    insert into pg_temp.military_attrition_allocations(unit_id,quantity,base_losses,remainder)
      select fu.unit_id,fu.quantity,
        floor(fu.quantity::numeric*losses/combat_quantity)::integer,
        fu.quantity::numeric*losses/combat_quantity-floor(fu.quantity::numeric*losses/combat_quantity)
      from fauxlore.military_formation_units fu
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where fu.formation_id=formation_row.id
        and case when formation_row.domain='naval' then u.domain='naval'
          else u.domain in ('land','siege') and u.category<>'Логистика' end;
    select coalesce(sum(base_losses),0)::integer into applied from pg_temp.military_attrition_allocations;
    remaining:=losses-applied;
    for unit_row in select * from pg_temp.military_attrition_allocations
      where base_losses<quantity order by remainder desc,unit_id loop
      if remaining<=0 then exit; end if;
      update pg_temp.military_attrition_allocations set base_losses=base_losses+1 where unit_id=unit_row.unit_id;
      remaining:=remaining-1;
    end loop;

    delete from fauxlore.military_formation_units fu
    using pg_temp.military_attrition_allocations a
    where fu.formation_id=formation_row.id and fu.unit_id=a.unit_id and a.base_losses>=fu.quantity;
    update fauxlore.military_formation_units fu
    set quantity=fu.quantity-a.base_losses
    from pg_temp.military_attrition_allocations a
    where fu.formation_id=formation_row.id and fu.unit_id=a.unit_id
      and a.base_losses>0 and a.base_losses<fu.quantity;

    select coalesce(jsonb_agg(jsonb_build_object('unit',u.name,'lost',a.base_losses) order by u.name),'[]'::jsonb)
      into loss_lines
    from pg_temp.military_attrition_allocations a join fauxlore.military_unit_catalog u on u.id=a.unit_id
    where a.base_losses>0;
    message_value:=format('Формирование «%s» потеряло %s ед. из-за истощения в провинции «%s»; расчётная потеря — %s%%. Состав потерь: %s.',
      formation_row.name,losses,province_row.name,loss_rate,
      (select string_agg((item->>'unit')||' — '||(item->>'lost'),', ' order by item->>'unit') from jsonb_array_elements(loss_lines) item));
    insert into fauxlore.notifications(account_id,kind,title,message)
      select ast.account_id,'military_attrition','Потери от истощения',message_value
      from fauxlore.account_states ast where ast.state_id=formation_row.state_id;
    resolved_count:=resolved_count+1;
  end loop;
  return resolved_count;
end
$function$;
revoke all on function fauxlore.resolve_military_attrition(integer,integer) from public,anon,authenticated;

-- Attrition resolves in the same atomic turn, immediately after movement.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  marker:='perform fauxlore.resolve_military_movement(calendar_row.year,calendar_row.turn);';
  replacement:=marker||E'\n  perform fauxlore.resolve_military_attrition(calendar_row.year,calendar_row.turn);';
  if position(marker in fn)=0 then raise exception 'Could not insert military attrition after movement'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

-- Preserve reduced unit counts in the administrator's reversible test-turn snapshot.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure),chr(13),'');
  old_fragment:='''province_weather'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.province_weather x)';
  new_fragment:=old_fragment||','||E'\n    '||'''military_formation_units'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.military_formation_units x)';
  if position(old_fragment in fn)=0 then raise exception 'Could not extend turn snapshot payload with unit composition'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:='''province_weather'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.province_weather x)';
  new_fragment:=old_fragment||','||E'\n      '||'''military_formation_units'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.military_formation_units x)';
  if position(old_fragment in fn)=0 then raise exception 'Could not extend test-turn before snapshot with unit composition'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='fauxlore.military_formations,fauxlore.military_movement_orders,fauxlore.province_weather in access exclusive mode;';
  new_fragment:='fauxlore.military_formations,fauxlore.military_formation_units,fauxlore.military_movement_orders,fauxlore.province_weather in access exclusive mode;';
  if position(old_fragment in fn)=0 then raise exception 'Could not lock military unit composition during test-turn rollback'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='delete from fauxlore.military_movement_orders where true; delete from fauxlore.province_weather where true;';
  new_fragment:='delete from fauxlore.military_movement_orders where true; delete from fauxlore.military_formation_units where true; delete from fauxlore.province_weather where true;';
  if position(old_fragment in fn)=0 then raise exception 'Could not clear unit composition before test-turn restore'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='''military_formations'',''military_movement_orders'',''province_weather'']) loop execute format(''alter table fauxlore.%I disable trigger user'',t);';
  new_fragment:='''military_formations'',''military_formation_units'',''military_movement_orders'',''province_weather'']) loop execute format(''alter table fauxlore.%I disable trigger user'',t);';
  if position(old_fragment in fn)=0 then raise exception 'Could not disable military composition revision trigger during restore'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='''military_formations'',''military_movement_orders'',''province_weather'']) loop execute format(''alter table fauxlore.%I enable trigger user'',t);';
  new_fragment:='''military_formations'',''military_formation_units'',''military_movement_orders'',''province_weather'']) loop execute format(''alter table fauxlore.%I enable trigger user'',t);';
  if position(old_fragment in fn)=0 then raise exception 'Could not restore military composition revision trigger after rollback'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='''turn_economy_reports'',''game_calendar'']) loop'||chr(10)||'      snap_row:=snap.payload->t;';
  new_fragment:='''turn_economy_reports'',''game_calendar'',''military_formations'',''military_formation_units'',''military_movement_orders'',''province_weather'']) loop'||chr(10)||'      snap_row:=snap.payload->t;';
  if position(old_fragment in fn)=0 then raise exception 'Could not add unit composition to test-turn restore list'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

select pg_notify('pgrst','reload schema');
