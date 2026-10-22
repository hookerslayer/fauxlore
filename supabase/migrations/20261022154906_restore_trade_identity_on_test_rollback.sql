do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$if t in ('state_characters','state_succession_events','state_birth_events','state_budget_ledger') then$old$;
  new_fragment:=$new$if t in ('state_characters','state_succession_events','state_birth_events','state_budget_ledger','trade_settlements','trade_market_settlements','trade_interzone_settlements') then$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn identity restore condition'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
