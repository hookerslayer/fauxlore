-- Qualify the operations-table request_id column against the API argument of the same name.
do $$
declare fn text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  if position('delete from fauxlore.operations where account_id=snap.actor_id and request_id=snap.advance_request_id;' in fn)=0 then return; end if;
  execute replace(fn,'delete from fauxlore.operations where account_id=snap.actor_id and request_id=snap.advance_request_id;',
    'delete from fauxlore.operations o where o.account_id=snap.actor_id and o.request_id=snap.advance_request_id;');
end $$;
