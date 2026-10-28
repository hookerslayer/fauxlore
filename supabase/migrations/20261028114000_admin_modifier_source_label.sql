do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
  marker:='select ''admin'',''Назначение администратора'',a.value,a.modifier_key,a.effect,a.unit,';
  replacement:='select ''admin'',a.source,a.value,a.modifier_key,a.effect,a.unit,';
  if position(marker in fn)=0 then raise exception 'Modifier source label insertion point is missing'; end if;
  execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
