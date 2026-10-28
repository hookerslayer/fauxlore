do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  marker:='actor:=fauxlore.current_account();';
  replacement:='if auth.uid() is not null then actor:=fauxlore.current_account(); end if;';
  if position(marker in fn)=0 then raise exception 'Wall auth marker missing'; end if;
  execute replace(fn,marker,replacement);
end $migration$;
