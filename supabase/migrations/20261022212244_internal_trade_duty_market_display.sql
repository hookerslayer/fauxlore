do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.trade_market_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:='''buyer_influence'',ms.buyer_influence)';
  new_fragment:='''buyer_influence'',ms.buyer_influence,''internal_duty_amount'',ms.internal_duty_amount)';
  if position('internal_duty_amount' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate trade market response fields'; end if;
    execute replace(fn,old_fragment,new_fragment);
  end if;
end $$;
notify pgrst,'reload schema';
