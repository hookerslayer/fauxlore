DO $migration$
DECLARE fn text; old_clause text; new_clause text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.admin_resources_api(text,integer,text,integer)'::regprocedure);
  old_clause:=$old$if action<>'adjust' or target_state is null or resource not in ('treasury','prestige','recruits')$old$;
  new_clause:=$new$if action is distinct from 'adjust' or target_state is null or resource is null or resource not in ('treasury','prestige','recruits')$new$;
  IF position(old_clause IN fn)=0 THEN RAISE EXCEPTION 'Admin resource validation clause missing'; END IF;
  EXECUTE replace(fn,old_clause,new_clause);
END
$migration$;
