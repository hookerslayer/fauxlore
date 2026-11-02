do $migration$
declare fn text; marker text := $old$'treasury',sp.treasury$old$;
begin
 fn:=pg_get_functiondef('public.judge_state_statistics_api()'::regprocedure);
 if position(marker in fn)=0 then raise exception 'judge statistics hook missing'; end if;
 execute replace(fn,marker,$new$'indicators',fauxlore.state_indicators(sp.state_id),'treasury',sp.treasury$new$);
end $migration$;
notify pgrst,'reload schema';
