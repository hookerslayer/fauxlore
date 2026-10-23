do $$
declare fn text; marker text:='official_race_id=designee.race_id,official_religion_id=designee.religion_id,';
begin
  fn:=pg_get_functiondef('fauxlore.resolve_designated_dictator()'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Designated succession identity marker missing'; end if;
  execute replace(fn,marker,'');
end $$;
notify pgrst,'reload schema';
