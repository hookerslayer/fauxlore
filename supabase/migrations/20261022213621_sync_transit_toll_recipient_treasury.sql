-- Keep the recipient's aggregate state profile balance in sync after a G toll.
do $$
declare fn text; patched text;
begin
  fn:=pg_get_functiondef('fauxlore.collect_third_state_trade_toll()'::regprocedure);
  if position('update fauxlore.state_profiles sp set treasury=' in fn)=0 then
    patched:=regexp_replace(fn,
      'update fauxlore\.state_treasuries set balance=greatest\(0,balance-\(settled_received-current_received\)\),updated_at=now\(\)[[:space:]]+where state_id=case when new\.direction=''forward'' then agreement\.to_state_id else agreement\.from_state_id end and estate=''Корона'';',
      E'update fauxlore.state_treasuries set balance=greatest(0,balance-(settled_received-current_received)),updated_at=now()\n        where state_id=case when new.direction=''forward'' then agreement.to_state_id else agreement.from_state_id end and estate=''Корона'';\n      update fauxlore.state_profiles sp set treasury=(select coalesce(sum(st.balance),0) from fauxlore.state_treasuries st where st.state_id=case when new.direction=''forward'' then agreement.to_state_id else agreement.from_state_id end) where sp.state_id=case when new.direction=''forward'' then agreement.to_state_id else agreement.from_state_id end;');
    if patched=fn then raise exception 'Could not locate recipient treasury deduction'; end if;
    execute patched;
  end if;
end $$;
