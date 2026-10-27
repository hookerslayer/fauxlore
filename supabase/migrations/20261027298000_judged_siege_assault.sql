-- Create judge-resolved storm battles from active sieges and carry their modifiers into the battle record.
alter table fauxlore.military_sieges
  add column if not exists assault_battle_id bigint references fauxlore.military_battles(id);

create or replace function public.military_siege_api(target_state integer default null)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; states integer[]; result jsonb;
begin
  actor:=fauxlore.current_account();
  select coalesce(array_agg(ast.state_id),'{}'::integer[]) into states
    from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states';
  if actor.role<>'admin' and (target_state is null or not target_state=any(states)) then
    raise sqlstate '42501' using message='Нет доступа к осадам этого государства';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',s.id,'province_id',s.province_id,'province_name',p.name,
    'attacker_state_id',s.attacker_state_id,'attacker_name',attacker.name,'defender_state_id',s.defender_state_id,
    'defender_name',defender.name,'status',s.status,'progress',s.progress,'breached',s.breached,
    'started_year',s.started_year,'started_turn',s.started_turn,'updated_year',s.updated_year,'updated_turn',s.updated_turn,
    'phase_log',s.phase_log,'fort_level',g.fort_level,'wall_level',g.wall_level,'assault_battle_id',s.assault_battle_id,
    'attacker_has_tower',exists(select 1 from fauxlore.military_formations f
      join fauxlore.military_formation_units fu on fu.formation_id=f.id
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where f.active and f.transported_by is null and f.domain='land' and f.state_id=s.attacker_state_id
        and f.province_id=s.province_id and fu.quantity>0 and u.name='Осадная башня'),
    'attacker_has_ram',exists(select 1 from fauxlore.military_formations f
      join fauxlore.military_formation_units fu on fu.formation_id=f.id
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where f.active and f.transported_by is null and f.domain='land' and f.state_id=s.attacker_state_id
        and f.province_id=s.province_id and fu.quantity>0 and u.name='Таран'))
    order by s.status='active' desc,s.updated_year desc,s.updated_turn desc,s.id desc),'[]'::jsonb)
  into result from fauxlore.military_sieges s
  join fauxlore.provinces p on p.id=s.province_id
  join fauxlore.map_categories attacker on attacker.layer='states' and attacker.id=s.attacker_state_id
  join fauxlore.map_categories defender on defender.layer='states' and defender.id=s.defender_state_id
  join fauxlore.garrison_sites g on g.province_id=s.province_id
  where actor.role='admin' or s.attacker_state_id=any(states) or s.defender_state_id=any(states);
  return jsonb_build_object('sieges',result);
end
$function$;
revoke all on function public.military_siege_api(integer) from public,anon;
grant execute on function public.military_siege_api(integer) to authenticated;

create or replace function public.military_siege_storm_api(province_key integer,attack_route text)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; siege_row fauxlore.military_sieges; calendar_row fauxlore.game_calendar;
  fort_value integer; wall_value integer; level_value integer; breach_value boolean;
  has_tower boolean; has_ram boolean; attack_multiplier numeric; defense_multiplier numeric;
  route_label text; fort_state text; participants_value jsonb; garrison_value jsonb;
  battle_key bigint; winner_name text; province_label text;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' then raise sqlstate '42501' using message='Начать штурм может только администратор'; end if;
  select * into siege_row from fauxlore.military_sieges s
    where s.province_id=province_key and s.status='active' for update;
  if not found then raise sqlstate '22023' using message='Активная осада в этой провинции не найдена'; end if;
  if siege_row.assault_battle_id is not null then
    raise sqlstate '22023' using message='Для этой осады уже ожидается решение по штурму';
  end if;
  perform 1 from fauxlore.military_wars w where w.active and
    ((w.attacker_id=siege_row.attacker_state_id and w.defender_id=siege_row.defender_state_id) or
     (w.defender_id=siege_row.attacker_state_id and w.attacker_id=siege_row.defender_state_id));
  if not found then raise sqlstate '22023' using message='Между сторонами осады больше нет активной войны'; end if;
  select g.fort_level,g.wall_level into fort_value,wall_value from fauxlore.garrison_sites g
    where g.province_id=province_key and g.state_id=siege_row.defender_state_id for update;
  if not found or coalesce(fort_value,0)+coalesce(wall_value,0)=0 then
    raise sqlstate '22023' using message='Укрепление осады больше не существует';
  end if;
  if not exists(select 1 from fauxlore.garrison_units gu where gu.province_id=province_key and gu.quantity>0) then
    raise sqlstate '22023' using message='В укреплении нет гарнизона для штурма';
  end if;
  if not exists(select 1 from fauxlore.military_formations f join fauxlore.military_formation_units fu on fu.formation_id=f.id
    where f.active and f.transported_by is null and f.domain='land' and f.state_id=siege_row.attacker_state_id
      and f.province_id=province_key and fu.quantity>0) then
    raise sqlstate '22023' using message='Осаждающая армия больше не находится в провинции';
  end if;
  select exists(select 1 from fauxlore.military_formations f
      join fauxlore.military_formation_units fu on fu.formation_id=f.id
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where f.active and f.transported_by is null and f.domain='land' and f.state_id=siege_row.attacker_state_id
        and f.province_id=province_key and fu.quantity>0 and u.name='Осадная башня'),
    exists(select 1 from fauxlore.military_formations f
      join fauxlore.military_formation_units fu on fu.formation_id=f.id
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id
      where f.active and f.transported_by is null and f.domain='land' and f.state_id=siege_row.attacker_state_id
        and f.province_id=province_key and fu.quantity>0 and u.name='Таран')
    into has_tower,has_ram;
  level_value:=least(3,greatest(0,fort_value+wall_value));
  breach_value:=siege_row.breached;
  fort_state:=case when breach_value then 'breached' else 'intact' end;
  route_label:=case attack_route when 'ladders' then 'Лестницы' when 'tower' then 'Осадная башня'
    when 'breach' then 'Штурм через пролом' when 'ram' then 'Таран' else null end;
  if route_label is null then raise sqlstate '22023' using message='Неизвестный способ штурма'; end if;
  if attack_route='tower' and not has_tower then raise sqlstate '22023' using message='Для атаки осадной башней она должна быть в составе осаждающей армии'; end if;
  if attack_route='breach' and not breach_value then raise sqlstate '22023' using message='Пролома ещё нет; выберите лестницы или дождитесь пролома'; end if;
  if attack_route='ram' and not has_ram then raise sqlstate '22023' using message='Для атаки тараном таран должен быть в составе осаждающей армии'; end if;
  attack_multiplier:=case attack_route when 'ladders' then 0.75 when 'tower' then 0.90
    when 'breach' then 1.0 when 'ram' then case when breach_value then 1.0 else 0.85 end end;
  defense_multiplier:=1+case level_value when 1 then 0.20 when 2 then 0.30 when 3 then 0.40 else 0 end
    *case when breach_value then 0.25 else 1 end;
  select * into calendar_row from fauxlore.game_calendar where singleton for update;
  if not found then raise sqlstate '55000' using message='Игровой календарь не найден'; end if;
  select p.name into province_label from fauxlore.provinces p where p.id=province_key;
  if exists(select 1 from fauxlore.military_battles b where b.province_id=province_key
    and b.domain='land' and b.year=calendar_row.year and b.turn=calendar_row.turn and b.status='pending') then
    raise sqlstate '23505' using message='В провинции уже ожидает решения другое сражение';
  end if;

  select coalesce(jsonb_agg(row_value.participant order by row_value.state_id,row_value.formation_id),'[]'::jsonb)
    into participants_value from (
      select f.state_id,f.id formation_id,jsonb_build_object('formation_id',f.id,'state_id',f.state_id,
        'state_name',coalesce(c.name,'Государство'),'formation_name',f.name,'kind',f.kind,'domain','land',
        'province_id',f.province_id,'position_x',f.position_x,'position_y',f.position_y,
        'units',(select coalesce(jsonb_agg(jsonb_build_object('unit_id',fu.unit_id,'name',u.name,'quantity',fu.quantity)
          order by fu.unit_id),'[]'::jsonb) from fauxlore.military_formation_units fu
          join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=f.id)) participant
      from fauxlore.military_formations f
      left join fauxlore.map_categories c on c.layer='states' and c.id=f.state_id
      where f.active and f.transported_by is null and f.domain='land' and f.province_id=province_key
        and f.state_id in (siege_row.attacker_state_id,siege_row.defender_state_id)
        and exists(select 1 from fauxlore.military_formation_units fu where fu.formation_id=f.id and fu.quantity>0)
    ) row_value;
  if jsonb_array_length(participants_value)=0 then raise sqlstate '22023' using message='Участники штурма не найдены'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('unit_id',gu.unit_id,'name',u.name,'quantity',gu.quantity)
      order by gu.unit_id),'[]'::jsonb) into garrison_value
    from fauxlore.garrison_units gu join fauxlore.military_unit_catalog u on u.id=gu.unit_id
    where gu.province_id=province_key and gu.quantity>0;
  participants_value:=participants_value||jsonb_build_array(jsonb_build_object(
    'formation_id',-province_key::bigint,'garrison_province_id',province_key,'state_id',siege_row.defender_state_id,
    'state_name',(select name from fauxlore.map_categories where layer='states' and id=siege_row.defender_state_id),
    'formation_name','Укреплённый гарнизон','kind','garrison','domain','land','province_id',province_key,
    'position_x',(select (p.center->>0)::double precision from fauxlore.provinces p where p.id=province_key),
    'position_y',(select (p.center->>1)::double precision from fauxlore.provinces p where p.id=province_key),
    'units',garrison_value,'siege_assault',jsonb_build_object('siege_id',siege_row.id,
      'attacker_state_id',siege_row.attacker_state_id,'defender_state_id',siege_row.defender_state_id,
      'route',attack_route,'route_label',route_label,'fortification_level',level_value,
      'fortification_state',fort_state,'attack_multiplier',attack_multiplier,'defense_multiplier',defense_multiplier)));

  insert into fauxlore.military_battles(province_id,domain,year,turn,status,participants)
    values(province_key,'land',calendar_row.year,calendar_row.turn,'pending',participants_value)
    returning id into battle_key;
  update fauxlore.military_sieges set assault_battle_id=battle_key where id=siege_row.id and status='active';
  delete from fauxlore.military_movement_orders mo using fauxlore.military_formations f
    where f.id=mo.formation_id and f.active and f.domain='land' and f.province_id=province_key
      and f.state_id=siege_row.attacker_state_id;
  insert into fauxlore.notifications(account_id,kind,title,message)
    select distinct ast.account_id,'military_siege','Начался штурм укрепления',
      format('В провинции «%s» начался штурм (%s). Исход зафиксирует судья.',province_label,route_label)
    from fauxlore.account_states ast where ast.layer='states'
      and ast.state_id in (siege_row.attacker_state_id,siege_row.defender_state_id);
  select name into winner_name from fauxlore.map_categories where layer='states' and id=siege_row.attacker_state_id;
  return jsonb_build_object('ok',true,'battle_id',battle_key,'province_id',province_key,
    'province_name',province_label,'attacker_name',winner_name,'route',attack_route,
    'attack_multiplier',attack_multiplier,'defense_multiplier',defense_multiplier,'fortification_state',fort_state);
end
$function$;
revoke all on function public.military_siege_storm_api(integer,text) from public,anon;
grant execute on function public.military_siege_storm_api(integer,text) to authenticated;

-- Allow fortified garrisons only when the battle was created by the siege-storm RPC.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.military_battle_api(bigint,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='        and g.fort_level=0 and g.wall_level=0 for update;';
  new_fragment:='        and ((g.fort_level=0 and g.wall_level=0) or (participant ? ''siege_assault'' and exists('||
    'select 1 from fauxlore.military_sieges s where s.id=(participant->''siege_assault''->>''siege_id'')::bigint'||
    ' and s.status=''active'' and s.assault_battle_id=battle_row.id))) for update;';
  if position(old_fragment in fn)=0 then raise exception 'Fortified garrison validation hook missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='  update fauxlore.military_battles set status=''resolved'',winner_state_id=winner_key,';
  new_fragment:='  if exists(select 1 from jsonb_array_elements(battle_row.participants) p where p ? ''siege_assault'') then'||chr(10)||
    '    update fauxlore.military_sieges s set status=case when winner_key=(p.value->''siege_assault''->>''attacker_state_id'')::integer'||
    ' then ''capitulated'' else ''lifted'' end,'||chr(10)||
    '      progress=case when winner_key=(p.value->''siege_assault''->>''attacker_state_id'')::integer then 100 else s.progress end,'||chr(10)||
    '      updated_year=(select year from fauxlore.game_calendar where singleton),'||
    '      updated_turn=(select turn from fauxlore.game_calendar where singleton),ended_at=now()'||chr(10)||
    '    from jsonb_array_elements(battle_row.participants) p(value)'||chr(10)||
    '    where p.value ? ''siege_assault'' and s.id=(p.value->''siege_assault''->>''siege_id'')::bigint'||
    '      and s.status=''active'' and s.assault_battle_id=battle_row.id;'||chr(10)||
    '    if not found then raise sqlstate ''40001'' using message=''Осада уже завершена; обновите страницу''; end if;'||chr(10)||
    '  end if;'||chr(10)||old_fragment;
  if position(old_fragment in fn)=0 then raise exception 'Siege battle finalization hook missing'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

select pg_notify('pgrst','reload schema');
