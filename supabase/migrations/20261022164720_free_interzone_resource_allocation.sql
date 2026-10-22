do $$ declare fn text; old_fragment text; new_fragment text;
begin
 fn:=replace(pg_get_functiondef('fauxlore.clear_trade_interzone_after_budget(integer,integer)'::regprocedure),chr(13),'');
 old_fragment:='qty numeric(14,2); amount_value numeric(14,2); seller_income numeric(14,2); fee_value numeric(14,2);';
 new_fragment:='qty numeric(14,2); amount_value numeric(14,2); seller_income numeric(14,2); fee_value numeric(14,2); buyer_quantity numeric(14,2); seller_remaining numeric(14,2); seller_pool numeric(14,2); supply_value numeric(14,2);';
 if position(old_fragment in fn)=0 then raise exception 'Missing inter-zone vars'; end if; fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:=$old$    if coalesce(base_price,0)<=0 then continue; end if;
    -- 2% of base value per crossed province border is paid by the buyer and
    -- removed from circulation. Seller receives the base price.
    delivered_price:=base_price*(1+.02*route_row.distance);
    for buyer_row in select state_id,balance from pg_temp.trade_zone_position
      where zone_id=route_row.to_zone_id and resource_name=route_row.resource_name and balance<0 order by state_id$old$;
 new_fragment:=$new$    select coalesce(sum(balance),0)::numeric(14,2) into supply_value from pg_temp.trade_zone_position
      where zone_id=route_row.from_zone_id and resource_name=route_row.resource_name and balance>0;
    for buyer_row in select a.state_id,a.allocation balance,a.influence
      from fauxlore.allocate_trade_market_demand(route_row.to_zone_id,route_row.resource_name,supply_value) a order by a.state_id$new$;
 if position(old_fragment in fn)=0 then raise exception 'Missing inter-zone route buyer queue'; end if; fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:=$old$      select coalesce(balance,0) into crown from fauxlore.state_treasuries where state_id=buyer_row.state_id and estate='Корона' for update;
      if coalesce(crown,0)<=0 then continue; end if;
      for seller_row in select state_id,balance from pg_temp.trade_zone_position
        where zone_id=route_row.from_zone_id and resource_name=route_row.resource_name and balance>0 and state_id<>buyer_row.state_id order by state_id
      loop
        if buyer_row.balance>=0 then exit; end if;
        select coalesce(balance,0) into crown from fauxlore.state_treasuries where state_id=buyer_row.state_id and estate='Корона' for update;
        qty:=least(-buyer_row.balance,seller_row.balance,floor(crown/delivered_price*100)/100);
        if qty<=0 then exit; end if;
        amount_value:=round(qty*delivered_price,2);
        seller_income:=round(qty*base_price,2);
        fee_value:=amount_value-seller_income;
        if amount_value>crown then qty:=greatest(0,qty-.01); amount_value:=round(qty*delivered_price,2); seller_income:=round(qty*base_price,2); fee_value:=amount_value-seller_income; end if;
        if qty<=0 or amount_value<=0 then exit; end if;
        update fauxlore.state_treasuries set balance=balance-amount_value,updated_at=now() where state_id=buyer_row.state_id and estate='Корона';
        insert into fauxlore.state_treasuries(state_id,estate,balance) values(seller_row.state_id,'Корона',0) on conflict(state_id,estate) do nothing;
        update fauxlore.state_treasuries set balance=balance+seller_income,updated_at=now() where state_id=seller_row.state_id and estate='Корона';$old$;
 new_fragment:=$new$      buyer_quantity:=buyer_row.balance;seller_remaining:=buyer_quantity;
      select coalesce(sum(balance),0) into seller_pool from pg_temp.trade_zone_position where zone_id=route_row.from_zone_id and resource_name=route_row.resource_name and balance>0;
      for seller_row in select state_id,balance amount,row_number() over(order by state_id) seq,count(*) over() total
        from pg_temp.trade_zone_position where zone_id=route_row.from_zone_id and resource_name=route_row.resource_name and balance>0 order by state_id
      loop
        if seller_remaining<=0 then exit; end if;
        if seller_row.seq=seller_row.total then qty:=least(seller_remaining,seller_row.amount);
        else qty:=least(seller_remaining,seller_row.amount,round(buyer_quantity*seller_row.amount/nullif(seller_pool,0),2)); end if;
        if qty<=0 then continue; end if;
        amount_value:=0;seller_income:=0;fee_value:=0;$new$;
 if position(old_fragment in fn)=0 then raise exception 'Missing inter-zone cash/payment block'; end if; fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:=$old$        insert into fauxlore.trade_interzone_settlements(year,turn,from_zone_id,to_zone_id,resource_name,buyer_state_id,seller_state_id,distance,quantity,unit_price,transport_cost,amount)
          values(year_value,turn_value,route_row.from_zone_id,route_row.to_zone_id,route_row.resource_name,buyer_row.state_id,seller_row.state_id,route_row.distance,qty,base_price,fee_value,amount_value);$old$;
 new_fragment:=$new$        insert into fauxlore.trade_interzone_settlements(year,turn,from_zone_id,to_zone_id,resource_name,buyer_state_id,seller_state_id,distance,quantity,unit_price,transport_cost,amount,buyer_influence)
          values(year_value,turn_value,route_row.from_zone_id,route_row.to_zone_id,route_row.resource_name,buyer_row.state_id,seller_row.state_id,route_row.distance,qty,0,0,0,buyer_row.influence);$new$;
 if position(old_fragment in fn)=0 then raise exception 'Missing inter-zone settlement insert'; end if; fn:=replace(fn,old_fragment,new_fragment);
 execute fn;
end $$;
