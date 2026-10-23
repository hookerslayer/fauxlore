do $$
declare fn text; marker text:='''recovery_target'',recovery_target)';
begin
  fn:=pg_get_functiondef('fauxlore.succession_api(text,text,jsonb,uuid)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Politics response marker missing'; end if;
  fn:=replace(fn,marker,'''recovery_target'',recovery_target,''status_changed_year'',status_changed_year,''status_changed_turn'',status_changed_turn,'||
    '''changed_this_turn'',status_changed_year=(select year from fauxlore.game_calendar where singleton) and status_changed_turn=(select turn from fauxlore.game_calendar where singleton))');
  execute fn;
end $$;
notify pgrst,'reload schema';
