-- Persist naval unit condition and feed current battle snapshots into the existing deterministic calculator.
alter table fauxlore.military_formations
  add column if not exists naval_state jsonb not null default '[]'::jsonb
  check (jsonb_typeof(naval_state)='array');

create or replace function fauxlore.reconcile_naval_state(formation_key bigint)
returns jsonb language sql stable security definer set search_path='' as $function$
  with f as (
    select id,naval_state from fauxlore.military_formations where id=formation_key and domain='naval'
  ), ships as (
    select f.id,fu.unit_id,u.name,u.recruit_cost,
      row_number() over(partition by fu.unit_id order by n.ship_no)::integer ship_no,
      s.value previous_state
    from f
    join fauxlore.military_formation_units fu on fu.formation_id=f.id
    join fauxlore.military_unit_catalog u on u.id=fu.unit_id
    cross join lateral generate_series(1,fu.quantity) n(ship_no)
    left join lateral (
      select item.value
      from jsonb_array_elements(f.naval_state) with ordinality item(value,ordinality)
      where (item.value->>'unit_id')::bigint=fu.unit_id
      order by item.ordinality offset n.ship_no-1 limit 1
    ) s on true
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',coalesce(previous_state->>'id',format('%s:%s:%s',id,unit_id,ship_no)),
    'unit_id',unit_id,'ship_no',ship_no,'type',name,
    'crew',least(recruit_cost,coalesce((previous_state->>'crew')::integer,recruit_cost)),
    'hull',greatest(0,coalesce((previous_state->>'hull')::numeric,case name when 'Когг' then 4 else 5 end)),
    'morale',greatest(0,least(100,coalesce((previous_state->>'morale')::numeric,100)))
  ) order by unit_id,ship_no),'[]'::jsonb)
  from ships;
$function$;
revoke all on function fauxlore.reconcile_naval_state(bigint) from public,anon,authenticated;

-- Update the currently installed encounter resolver, preserving its transport and order-freezing safeguards.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.resolve_military_encounters(integer,integer)'::regprocedure),chr(13),'');
  marker:='    select coalesce(jsonb_agg(jsonb_build_object(';
  replacement:='    if candidate.domain=''naval'' then'||chr(10)||
    '      update fauxlore.military_formations f set naval_state=fauxlore.reconcile_naval_state(f.id)'||chr(10)||
    '      where f.active and f.transported_by is null and f.domain=''naval'' and f.province_id=candidate.province_id'||chr(10)||
    '        and exists(select 1 from fauxlore.military_formations enemy join fauxlore.military_wars w on w.active and'||chr(10)||
    '          ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))'||chr(10)||
    '          where enemy.active and enemy.transported_by is null and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id);'||chr(10)||
    '    end if;'||chr(10)||marker;
  if position(marker in fn)=0 then raise exception 'Could not initialize ship state before naval encounter creation'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='''position_y'',f.position_y,';
  replacement:=marker||chr(10)||
    '        ''naval_state'',case when f.domain=''naval'' then f.naval_state else ''[]''::jsonb end,'||chr(10)||
    '        ''leader_skills'',coalesce((select l.skills from fauxlore.military_leaders l where l.id=f.leader_id),''{}''::jsonb),'||chr(10)||
    '        ''passengers'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',army.id,''name'',army.name,''unit_groups'','||
    '(select coalesce(jsonb_agg(jsonb_build_object(''type'',u.name,''count'',fu.quantity) order by fu.unit_id),''[]''::jsonb)'||
    ' from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=army.id)) order by army.id),''[]''::jsonb)'||
    ' from fauxlore.military_formations army where army.transported_by=f.id and army.active),';
  if position(marker in fn)=0 then raise exception 'Could not snapshot ship, commander and passenger details'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

-- Store surviving vessel conditions and captured ships when the judge confirms the calculated result.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=replace(pg_get_functiondef('public.military_battle_api(bigint,jsonb)'::regprocedure),chr(13),'');
  marker:='  if battle_row.domain=''land'' then'||chr(10)||
    '    select category_id into province_owner';
  replacement:='  if battle_row.domain=''naval'' then'||chr(10)||
    '    if jsonb_typeof(coalesce(payload->''naval_states'',''[]''::jsonb))<>''array'' then'||chr(10)||
    '      raise sqlstate ''22023'' using message=''Данные кораблей имеют неверный формат'';'||chr(10)||
    '    end if;'||chr(10)||
    '    if exists(select 1 from jsonb_array_elements(battle_row.participants) p where p->>''domain''=''naval'' and'||chr(10)||
    '      (select count(*) from jsonb_array_elements(coalesce(payload->''naval_states'',''[]''::jsonb)) x'||chr(10)||
    '       where (x->>''formation_id'')::bigint=(p->>''formation_id'')::bigint)<>1) then'||chr(10)||
    '      raise sqlstate ''22023'' using message=''Нужно сохранить состояние каждого флота из сражения'';'||chr(10)||
    '    end if;'||chr(10)||
    '    if exists(select 1 from jsonb_array_elements(coalesce(payload->''naval_states'',''[]''::jsonb)) x'||chr(10)||
    '      where not exists(select 1 from jsonb_array_elements(battle_row.participants) p'||chr(10)||
    '        where (p->>''formation_id'')::bigint=(x->>''formation_id'')::bigint and p->>''domain''=''naval'')) then'||chr(10)||
    '      raise sqlstate ''22023'' using message=''В расчёт включено формирование вне этого сражения'';'||chr(10)||
    '    end if;'||chr(10)||
    '    update fauxlore.military_formations f set naval_state=x.value->''ships'''||chr(10)||
    '      from jsonb_array_elements(coalesce(payload->''naval_states'',''[]''::jsonb)) x(value)'||chr(10)||
    '      where f.id=(x.value->>''formation_id'')::bigint and f.domain=''naval'';'||chr(10)||
    '    insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)'||chr(10)||
    '      select (c.value->>''target_formation_id'')::bigint,(c.value->>''unit_id'')::bigint,1'||chr(10)||
    '      from jsonb_array_elements(coalesce(payload->''naval_captures'',''[]''::jsonb)) c(value)'||chr(10)||
    '      where exists(select 1 from jsonb_array_elements(battle_row.participants) p'||chr(10)||
    '        where (p->>''formation_id'')::bigint=(c.value->>''target_formation_id'')::bigint'||chr(10)||
    '          and (p->>''state_id'')::integer=winner_key and p->>''domain''=''naval'')'||chr(10)||
    '      on conflict(formation_id,unit_id) do update set quantity=fauxlore.military_formation_units.quantity+excluded.quantity;'||chr(10)||
    '    update fauxlore.military_formations f set naval_state=f.naval_state||jsonb_build_array(c.value->''ship'')'||chr(10)||
    '      from jsonb_array_elements(coalesce(payload->''naval_captures'',''[]''::jsonb)) c(value)'||chr(10)||
    '      where f.id=(c.value->>''target_formation_id'')::bigint and f.domain=''naval'';'||chr(10)||
    '  end if;'||chr(10)||marker;
  if position(marker in fn)=0 then raise exception 'Could not insert naval calculator results into battle resolution'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='''province_id'',battle_row.province_id,''transported_armies_lost'',transported_losses),resolved_at=now() where id=battle_row.id;';
  replacement:='''province_id'',battle_row.province_id,''transported_armies_lost'',transported_losses,''naval_calculation'',coalesce(payload->''naval_report'',''null''::jsonb)),resolved_at=now() where id=battle_row.id;';
  if position(marker in fn)=0 then raise exception 'Could not save naval battle report'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

select pg_notify('pgrst','reload schema');
