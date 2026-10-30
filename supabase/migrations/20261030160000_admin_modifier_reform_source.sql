-- A confirmed reform can be recorded as the source of an administrator-assigned
-- mechanical effect; the modifier remains governed by the same active formula.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
  old_fragment:='''effect'',a.effect,''value'',a.value,''unit'',a.unit,''remaining_turns''';
  new_fragment:='''effect'',a.effect,''value'',a.value,''unit'',a.unit,''source'',a.source,''remaining_turns''';
  if position(old_fragment in fn)=0 then raise exception 'Modifier snapshot fields changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='values(state_key,province_key,def.modifier_key,def.effect,value_key,def.unit,def.source_key,calendar_row.year,calendar_row.turn,';
  new_fragment:='values(state_key,province_key,def.modifier_key,def.effect,value_key,def.unit,coalesce(nullif(left(btrim(payload->>''source''),120),''''),''Назначение администратора''),calendar_row.year,calendar_row.turn,';
  if position(old_fragment in fn)=0 then raise exception 'Modifier assignment source changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
notify pgrst,'reload schema';
