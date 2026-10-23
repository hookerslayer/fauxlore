do $$
declare fn text; marker text:='indicators:=fauxlore.state_indicators(state_row.state_id);';
begin
  fn:=pg_get_functiondef('fauxlore.apply_turn_population_and_recruit_growth()'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Growth trigger indicator marker missing'; end if;
  fn:=replace(fn,marker,'select x.value->''indicators_at_turn_start'' into indicators'||chr(10)||
    '      from jsonb_array_elements(coalesce(report_value,''[]''::jsonb)) with ordinality x(value,ord)'||chr(10)||
    '      where x.value->>''id'' ~ ''^\d+$'' and (x.value->>''id'')::integer=state_row.state_id;'||chr(10)||
    '    if indicators is null then indicators:=fauxlore.state_indicators(state_row.state_id); end if;');
  execute fn;
end $$;
notify pgrst,'reload schema';
