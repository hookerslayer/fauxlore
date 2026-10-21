do $migration$
declare
  definition text;
  anchor text := 'raise sqlstate ''22023'' using message=''Выбирать можно только сухопутные провинции''; end if;';
  addition text := E'\n    if (select count(*) from fauxlore.province_values v where v.province_id=any(array(select x::integer from jsonb_array_elements_text(body->''province_ids'') e(x))) and v.layer=''trade'')<>5 then\n      raise sqlstate ''22023'' using message=''У каждой выбранной провинции должна быть назначена торговая зона''; end if;';
begin
  select pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  if position(anchor in definition)=0 then
    raise exception 'Expected land province validation was not found in fauxlore.registration_api';
  end if;
  execute replace(definition,anchor,anchor||addition);
end
$migration$;
