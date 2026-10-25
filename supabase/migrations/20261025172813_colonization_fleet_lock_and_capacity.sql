DO $migration$
DECLARE fn text; marker text; replacement text;
BEGIN
  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  marker:='''name'',u.name,''quantity'',fu.quantity,''upkeep'',u.upkeep';
  replacement:=marker||',''capacity'',u.capacity';
  IF position(marker IN fn)=0 THEN RAISE EXCEPTION 'Military snapshot unit fields marker missing'; END IF;
  fn:=replace(fn,marker,replacement);
  marker:='if action=''snapshot'' then';
  replacement:='if action in (''hire'',''assign_leader'') and exists(select 1 from fauxlore.colonization_missions cm where cm.status=''active'' and cm.fleet_id=(payload->>''formation_id'')::bigint) then'||E'\n'||
    '  raise sqlstate ''22023'' using message=''Флотилия занята колонизационной миссией''; end if;'||E'\n'||marker;
  IF position(marker IN fn)=0 THEN RAISE EXCEPTION 'Military action dispatch insertion point missing'; END IF;
  EXECUTE replace(fn,marker,replacement);
END
$migration$;
