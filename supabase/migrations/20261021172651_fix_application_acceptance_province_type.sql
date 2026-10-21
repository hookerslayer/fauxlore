do $migration$
declare
  definition text;
  old_fragment constant text := 'province_type=case when id=app.capital_province_id then ''Столица'' else ''Регион'' end,';
  new_fragment constant text := 'province_type=case when id=app.capital_province_id then ''Столичная'' else ''Регион'' end,';
begin
  select pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  if position(old_fragment in definition)=0 then
    raise exception 'Expected obsolete province type assignment was not found in fauxlore.registration_api';
  end if;
  execute replace(definition,old_fragment,new_fragment);
end
$migration$;
