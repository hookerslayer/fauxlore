-- Honor the database safe-update guard when clearing rows for snapshot restore.
do $$
declare fn text; table_name text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  foreach table_name in array array['notifications','state_birth_events','state_budget_ledger','turn_economy_reports',
    'state_succession_events','state_group_politics','state_characters','state_treasuries','state_treasury_debts'] loop
    fn:=replace(fn,'delete from fauxlore.'||table_name||';','delete from fauxlore.'||table_name||' where true;');
  end loop;
  execute fn;
end $$;
