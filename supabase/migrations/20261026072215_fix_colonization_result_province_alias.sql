DO $migration$
DECLARE fn text; old_fragment text; new_fragment text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  old_fragment:=$old$'province_id',target_key,'province_name',province_info.name,'turns'$old$;
  new_fragment:=$new$'province_id',target_key,'province_name',p.name,'turns'$new$;
  IF position(old_fragment IN fn)=0 THEN
    RAISE EXCEPTION 'Colonization result province alias insertion point missing';
  END IF;
  EXECUTE replace(fn,old_fragment,new_fragment);
END
$migration$;
