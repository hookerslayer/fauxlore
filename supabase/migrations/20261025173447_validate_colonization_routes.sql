DO $migration$
DECLARE fn text; marker text; replacement text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  marker:='if cardinality(route_ids)<1 or cardinality(route_ids)>40 then raise sqlstate ''22023'' using message=''Маршрут должен содержать от 1 до 40 морских провинций''; end if;';
  replacement:=marker||E'\n'||
    '    if cardinality(route_ids)<>(select count(distinct route_id)::integer from unnest(route_ids) as routes(route_id)) then raise sqlstate ''22023'' using message=''Нельзя повторно включать морскую провинцию в маршрут''; end if;';
  IF position(marker IN fn)=0 THEN RAISE EXCEPTION 'Colonization route validation insertion point missing'; END IF;
  EXECUTE replace(fn,marker,replacement);
END
$migration$;
