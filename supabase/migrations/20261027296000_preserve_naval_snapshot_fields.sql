-- Keep naval calculator state and commander/passenger snapshots when extending encounters with garrisons.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.resolve_military_encounters(integer,integer)'::regprocedure),chr(13),'');
  marker:='    with sides as (';
  replacement:='    if candidate.domain=''naval'' then'||chr(10)||
    '      update fauxlore.military_formations f set naval_state=fauxlore.reconcile_naval_state(f.id)'||chr(10)||
    '      where f.active and f.transported_by is null and f.domain=''naval'' and f.province_id=candidate.province_id'||chr(10)||
    '        and exists(select 1 from fauxlore.military_formations enemy join fauxlore.military_wars w on w.active and'||chr(10)||
    '          ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))'||chr(10)||
    '          where enemy.active and enemy.transported_by is null and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id);'||chr(10)||
    '    end if;'||chr(10)||marker;
  if position(marker in fn)=0 then raise exception 'Naval state reconciliation insertion marker missing'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='''domain'',f.domain,''province_id'',f.province_id,''position_x'',f.position_x,''position_y'',f.position_y,';
  replacement:=marker||chr(10)||
    '        ''naval_state'',case when f.domain=''naval'' then f.naval_state else ''[]''::jsonb end,'||chr(10)||
    '        ''leader_skills'',coalesce((select l.skills from fauxlore.military_leaders l where l.id=f.leader_id),''{}''::jsonb),'||chr(10)||
    '        ''passengers'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',army.id,''name'',army.name,''unit_groups'','||
    '(select coalesce(jsonb_agg(jsonb_build_object(''type'',u.name,''count'',fu.quantity) order by fu.unit_id),''[]''::jsonb)'||
    ' from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=army.id))'||
    ' order by army.id),''[]''::jsonb) from fauxlore.military_formations army where army.transported_by=f.id and army.active),';
  if position(marker in fn)=0 then raise exception 'Naval participant payload marker missing'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

select pg_notify('pgrst','reload schema');
