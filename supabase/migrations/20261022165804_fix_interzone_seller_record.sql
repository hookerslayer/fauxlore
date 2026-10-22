do $$ declare fn text; old_fragment text; begin
 fn:=replace(pg_get_functiondef('fauxlore.clear_trade_interzone_after_budget(integer,integer)'::regprocedure),chr(13),'');
 old_fragment:='seller_row.balance:=seller_row.balance-qty;';
 if position(old_fragment in fn)=0 then raise exception 'Missing obsolete inter-zone seller record assignment'; end if;
 execute replace(fn,old_fragment,'null;');
end $$;
