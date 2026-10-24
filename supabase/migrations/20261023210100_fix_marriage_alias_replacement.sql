-- Correct doubled aliases produced by the first collision-fix migration.
do $$
declare fn text;
begin
  select pg_get_functiondef('fauxlore.marriage_dissolution_api(text,text,jsonb,uuid)'::regprocedure) into fn;
  fn:=replace(fn,'person_person_a.','person_a.');
  fn:=replace(fn,'person_person_b.','person_b.');
  execute fn;
end $$;
notify pgrst,'reload schema';
