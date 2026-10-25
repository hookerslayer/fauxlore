-- Resolve the PL/pgSQL variable/column collision when returning the result
-- from a successful candidate selection.
do $migration$
declare
  function_definition text;
  old_fragment constant text := 'return (select result from fauxlore.operations where account_id=a.id and operations.request_id=succession_api.request_id);';
  new_fragment constant text := 'return (select o.result from fauxlore.operations as o where o.account_id=a.id and o.request_id=succession_api.request_id);';
begin
  select pg_get_functiondef('fauxlore.succession_api(text,text,jsonb,uuid)'::regprocedure)
    into function_definition;

  if position(old_fragment in function_definition)=0 then
    if position(new_fragment in function_definition)>0 then
      return;
    end if;
    raise exception 'Expected candidate-selection return expression was not found in succession_api';
  end if;

  execute replace(function_definition,old_fragment,new_fragment);
end
$migration$;
