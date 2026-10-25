-- Increase the province recruit-limit base from one recruit per 100 residents
-- to one recruit per 10 residents. Keep the client, state aggregate, and
-- province-value calculation in sync.
DO $migration$
DECLARE
  fn text;
  old_fragment text;
  new_fragment text;
BEGIN
  SELECT pg_get_functiondef('fauxlore.state_recruitment(integer)'::regprocedure)
  INTO fn;
  old_fragment := 'p.population::numeric/100*(cfg.config#>>array[''recruitLimitModifiers'',p.province_type])::numeric*';
  new_fragment := 'p.population::numeric/10*(cfg.config#>>array[''recruitLimitModifiers'',p.province_type])::numeric*';
  IF fn IS NULL OR position(old_fragment IN fn) = 0 THEN
    RAISE EXCEPTION 'Expected recruit limit formula not found in state_recruitment';
  END IF;
  EXECUTE replace(fn, old_fragment, new_fragment);

  SELECT pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure)
  INTO fn;
  old_fragment := 'recruit_limit:=round(population/100';
  new_fragment := 'recruit_limit:=round(population/10';
  IF fn IS NULL OR position(old_fragment IN fn) = 0 THEN
    RAISE EXCEPTION 'Expected recruit limit formula not found in province_value_for_state';
  END IF;
  EXECUTE replace(fn, old_fragment, new_fragment);
END
$migration$;
