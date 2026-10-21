do $migration$
declare
  definition text;
  old_fragment constant text := 'jsonb_object_length(body->''principles'')<>5';
  new_fragment constant text := '(select count(*) from jsonb_object_keys(case when jsonb_typeof(body->''principles'')=''object'' then body->''principles'' else ''{}''::jsonb end))<>5';
begin
  select pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  if position(old_fragment in definition)=0 then
    raise exception 'Expected obsolete JSONB length check was not found in fauxlore.registration_api';
  end if;
  execute replace(definition,old_fragment,new_fragment);
end
$migration$;
