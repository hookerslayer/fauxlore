do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
  marker:='''duration'',case when source_kind=''admin'' and target_province_id is not null then ''Провинция'' else ''Постоянный'' end,';
  replacement:='''duration'',case when source_kind=''admin'' then coalesce((select case when a.expires_year is null then ''Постоянный'' else ''До хода ''||a.expires_turn||'' (''||a.expires_year||'')'' end from fauxlore.admin_modifier_assignments a where a.state_id=target_state and a.province_id is not distinct from modifiers.target_province_id and a.modifier_key=modifiers.modifier_key and a.effect=modifiers.effect and a.value=modifiers.value and a.source=modifiers.source_key order by a.created_at desc limit 1),''Постоянный'') else ''Постоянный'' end,';
  if position(marker in fn)=0 then raise exception 'Modifier duration label insertion point is missing'; end if;
  execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
