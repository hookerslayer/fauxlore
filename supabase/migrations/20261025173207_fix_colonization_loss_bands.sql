DO $migration$
DECLARE fn text; old_fragment text; new_fragment text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  old_fragment:='when final_value<40 then 20 when final_value<60 then 15';
  new_fragment:='when final_value<40 then 20 when final_value<50 then 20 when final_value<60 then 15';
  IF position(old_fragment IN fn)=0 THEN RAISE EXCEPTION 'Colonization loss band insertion point missing'; END IF;
  EXECUTE replace(fn,old_fragment,new_fragment);
END
$migration$;
