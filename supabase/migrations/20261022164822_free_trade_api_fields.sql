do $$ declare fn text; old_fragment text; new_fragment text;
begin
 fn:=replace(pg_get_functiondef('fauxlore.trade_market_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
 old_fragment:='''quantity'',ms.quantity,''unit_price'',ms.unit_price,''amount'',ms.amount'; new_fragment:='''quantity'',ms.quantity,''buyer_influence'',ms.buyer_influence';
 if position(old_fragment in fn)=0 then raise exception 'Missing local market API fields'; end if; execute replace(fn,old_fragment,new_fragment);
 fn:=replace(pg_get_functiondef('fauxlore.trade_interzone_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
 old_fragment:='''distance'',x.distance,''quantity'',x.quantity,''unit_price'',x.unit_price,''transport_cost'',x.transport_cost,''amount'',x.amount'; new_fragment:='''distance'',x.distance,''quantity'',x.quantity,''buyer_influence'',x.buyer_influence';
 if position(old_fragment in fn)=0 then raise exception 'Missing inter-zone API fields'; end if; execute replace(fn,old_fragment,new_fragment);
end $$;
notify pgrst,'reload schema';
