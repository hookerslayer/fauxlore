-- The public map needs display data, not the rules and prices used by server projections.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('fauxlore.map_payload()'::regprocedure) into definition;
  if position('if account_row.role = ''admin'' then return result; end if;' in definition)=0
    or position('return jsonb_set(jsonb_set(result,''{provinces}'',provinces),''{categories}'',categories);' in definition)=0 then
    raise exception 'Expected map response branches not found';
  end if;
  definition:=replace(definition,
    'if account_row.role = ''admin'' then return result; end if;',
    'if account_row.role = ''admin'' then return result - ''economy_config''; end if;');
  definition:=replace(definition,
    'return jsonb_set(jsonb_set(result,''{provinces}'',provinces),''{categories}'',categories);',
    'return jsonb_set(jsonb_set(result,''{provinces}'',provinces),''{categories}'',categories) - ''economy_config'';');
  execute definition;
end $$;
