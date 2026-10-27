-- Record hostile formations that end a turn in the same province and freeze them
-- until the judge resolves the encounter.
create table fauxlore.military_battles(
  id bigint generated always as identity primary key,
  province_id integer not null references fauxlore.provinces(id),
  domain text not null check(domain in ('land','naval')),
  year integer not null,
  turn integer not null,
  status text not null default 'pending' check(status in ('pending','resolved','cancelled')),
  participants jsonb not null default '[]'::jsonb check(jsonb_typeof(participants)='array'),
  winner_state_id integer,
  result jsonb,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique(province_id,domain,year,turn)
);
alter table fauxlore.military_battles enable row level security;
revoke all on fauxlore.military_battles from public,anon,authenticated;
create index military_battles_pending_turn_idx on fauxlore.military_battles(status,year,turn) where status='pending';

create or replace function fauxlore.resolve_military_encounters(year_value integer,turn_value integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare candidate record; battle_id bigint; participants_value jsonb; state_ids integer[]; province_name text;
  state_name text; message_value text; created_count integer:=0;
begin
  for candidate in
    select f.province_id,f.domain
    from fauxlore.military_formations f
    where f.active and f.domain in ('land','naval') and exists(
      select 1 from fauxlore.military_formations enemy
      join fauxlore.military_wars w on w.active and
        ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or
         (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))
      where enemy.active and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id)
    group by f.province_id,f.domain
    order by f.province_id,f.domain
  loop
    battle_id:=null;
    insert into fauxlore.military_battles(province_id,domain,year,turn)
      values(candidate.province_id,candidate.domain,year_value,turn_value)
      on conflict(province_id,domain,year,turn) do nothing
      returning id into battle_id;
    if battle_id is null then continue; end if;

    select coalesce(jsonb_agg(jsonb_build_object(
        'formation_id',f.id,'state_id',f.state_id,'state_name',coalesce(state_category.name,'Государство'),
        'formation_name',f.name,'domain',f.domain,'province_id',f.province_id,
        'position_x',f.position_x,'position_y',f.position_y,
        'units',(select coalesce(jsonb_agg(jsonb_build_object('unit_id',fu.unit_id,'name',u.name,'quantity',fu.quantity)
          order by fu.unit_id),'[]'::jsonb)
          from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
          where fu.formation_id=f.id)
      ) order by f.state_id,f.id),'[]'::jsonb),
      coalesce(array_agg(distinct f.state_id order by f.state_id),'{}'::integer[])
    into participants_value,state_ids
    from fauxlore.military_formations f
    left join fauxlore.map_categories state_category on state_category.layer='states' and state_category.id=f.state_id
    where f.active and f.domain=candidate.domain and f.province_id=candidate.province_id
      and exists(select 1 from fauxlore.military_formations enemy join fauxlore.military_wars w on w.active and
          ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or
           (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))
        where enemy.active and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id);

    update fauxlore.military_battles set participants=participants_value where id=battle_id;
    delete from fauxlore.military_movement_orders mo
      where participants_value @> jsonb_build_array(jsonb_build_object('formation_id',mo.formation_id));
    select p.name into province_name from fauxlore.provinces p where p.id=candidate.province_id;
    state_name:=case candidate.domain when 'naval' then 'морское столкновение' else 'сухопутное сражение' end;
    message_value:=format('В провинции «%s» автоматически началось %s. Формирования остановлены до решения судьи.',province_name,state_name);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'military_battle','Началось сражение',message_value
      from fauxlore.account_states ast where ast.state_id=any(state_ids);
    created_count:=created_count+1;
  end loop;
  return created_count;
end
$function$;
revoke all on function fauxlore.resolve_military_encounters(integer,integer) from public,anon,authenticated;

-- Resolve encounters after movement and attrition inside the existing atomic turn.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  marker:='perform fauxlore.resolve_military_attrition(calendar_row.year,calendar_row.turn);';
  replacement:=marker||E'\n  perform fauxlore.resolve_military_encounters(calendar_row.year,calendar_row.turn);';
  if position(marker in fn)=0 then raise exception 'Could not add military encounter phase after attrition'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

-- Do not allow a new route order while a formation waits for a judge's decision.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.military_movement_api(text,bigint,jsonb)'::regprocedure),chr(13),'');
  marker:='if jsonb_typeof(route_value) is distinct from ''array''';
  replacement:='if exists(select 1 from fauxlore.military_battles b where b.status=''pending'' and b.participants @> jsonb_build_array(jsonb_build_object(''formation_id'',formation_key))) then'||chr(10)||
    '    raise sqlstate ''55000'' using message=''Формирование ожидает решения судьи по сражению'';'||chr(10)||
    '  end if;'||chr(10)||'  '||marker;
  if position(marker in fn)=0 then raise exception 'Could not lock movement orders during a pending battle'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

-- Show pending encounters in the regular military snapshot for participants and admins.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='''diplomacy'',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc),''[]''::jsonb)'||chr(10)||
    '     from fauxlore.military_diplomacy d where d.from_state_id=sid or d.to_state_id=sid),';
  new_fragment:=old_fragment||E'\n   '||'''battles'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',b.id,''province_id'',b.province_id,''province_name'',p.name,''domain'',b.domain,''year'',b.year,''turn'',b.turn,''participants'',b.participants) order by b.created_at),''[]''::jsonb)'||chr(10)||
    '     from fauxlore.military_battles b join fauxlore.provinces p on p.id=b.province_id where b.status=''pending'' and '||
    '(is_admin or exists(select 1 from jsonb_array_elements(b.participants) participant where (participant->>''state_id'')::integer=sid))),';
  if position(old_fragment in fn)=0 then raise exception 'Could not expose pending military encounters in the snapshot'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

-- Keep reversible test turns from losing or duplicating newly generated encounters.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure),chr(13),'');
  old_fragment:='''military_formation_units'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.military_formation_units x)';
  new_fragment:=old_fragment||','||E'\n    '||'''military_battles'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.military_battles x)';
  if position(old_fragment in fn)=0 then raise exception 'Could not include encounters in the turn snapshot'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:='''military_formation_units'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.military_formation_units x)';
  new_fragment:=old_fragment||','||E'\n      '||'''military_battles'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.military_battles x)';
  if position(old_fragment in fn)=0 then raise exception 'Could not save encounters before the reversible test turn'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='fauxlore.military_formations,fauxlore.military_formation_units,fauxlore.military_movement_orders,fauxlore.province_weather in access exclusive mode;';
  new_fragment:='fauxlore.military_formations,fauxlore.military_formation_units,fauxlore.military_movement_orders,fauxlore.military_battles,fauxlore.province_weather in access exclusive mode;';
  if position(old_fragment in fn)=0 then raise exception 'Could not lock encounters during the reversible test turn'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='delete from fauxlore.military_movement_orders where true; delete from fauxlore.military_formation_units where true; delete from fauxlore.province_weather where true;';
  new_fragment:='delete from fauxlore.military_movement_orders where true; delete from fauxlore.military_formation_units where true; delete from fauxlore.military_battles where true; delete from fauxlore.province_weather where true;';
  if position(old_fragment in fn)=0 then raise exception 'Could not clear generated encounters before test-turn restore'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='''military_formations'',''military_formation_units'',''military_movement_orders'',''province_weather'']) loop'||chr(10)||'      snap_row:=snap.payload->t;';
  new_fragment:='''military_formations'',''military_formation_units'',''military_movement_orders'',''military_battles'',''province_weather'']) loop'||chr(10)||'      snap_row:=snap.payload->t;';
  if position(old_fragment in fn)=0 then raise exception 'Could not restore military encounters after a test turn'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
select pg_notify('pgrst','reload schema');
