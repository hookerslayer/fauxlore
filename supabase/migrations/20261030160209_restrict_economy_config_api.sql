-- Constants are loaded only by the administrator editor.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('fauxlore.economy_config_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  if position('if path=''economy/config'' and method=''GET'' then return (select config from fauxlore.economy_parameters where singleton=true); end if;' in definition)=0 then
    raise exception 'Public economy config branch not found';
  end if;
  definition:=replace(definition,
    'if path=''economy/config'' and method=''GET'' then return (select config from fauxlore.economy_parameters where singleton=true); end if;',
    'if path=''economy/config'' then raise sqlstate ''42501'' using message=''Нужна роль администратора''; end if;');
  execute definition;
end $$;
