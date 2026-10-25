DO $migration$
DECLARE fn text; marker text; replacement text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  marker:='target_key:=(payload->>''province_id'')::integer;';
  replacement:='select year,turn into year_value,turn_value from fauxlore.game_calendar where singleton=true for share;'||E'\n'||
    '  select * into state_row from fauxlore.state_profiles where state_id=state_key for update;'||E'\n'||marker;
  IF position(marker IN fn)=0 THEN RAISE EXCEPTION 'Colonization attempt lock insertion point missing'; END IF;
  EXECUTE replace(fn,marker,replacement);
END
$migration$;
