DO $migration$
DECLARE fn text; old_join text; new_join text; old_name text; new_name text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  old_join:=$old$join fauxlore.provinces p on p.id=m.province_id join fauxlore.map_categories c$old$;
  new_join:=$new$join fauxlore.provinces province_info on province_info.id=m.province_id join fauxlore.map_categories c$new$;
  old_name:=$old$'province_name',p.name$old$;
  new_name:=$new$'province_name',province_info.name$new$;
  IF position(old_join IN fn)=0 OR position(old_name IN fn)=0 THEN
    RAISE EXCEPTION 'Colonization snapshot province alias insertion point missing';
  END IF;
  fn:=replace(fn,old_join,new_join);
  fn:=replace(fn,old_name,new_name);
  EXECUTE fn;
END
$migration$;
