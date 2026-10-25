-- The registration notification should reflect that the starting reserve is
-- now initialized to the state's calculated recruit limit.
DO $migration$
DECLARE fn text; old_text text; new_text text;
BEGIN
  SELECT pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure) INTO fn;
  old_text := 'Резерв войск: 0 (лимит рекрутов ещё не рассчитан).';
  new_text := 'Начальный резерв рекрутов заполнен до текущего лимита.';
  IF fn IS NULL OR position(old_text IN fn)=0 THEN
    RAISE EXCEPTION 'Obsolete initial recruit notification was not found';
  END IF;
  EXECUTE replace(fn,old_text,new_text);
END
$migration$;
