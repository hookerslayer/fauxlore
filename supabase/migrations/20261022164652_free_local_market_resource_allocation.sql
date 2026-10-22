do $$
declare fn text; old_fragment text; new_fragment text;
begin
 fn:=replace(pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure),chr(13),'');
 old_fragment:='if total_supply<=0 or total_demand<=0 or base_value<=0 then continue; end if;'; new_fragment:='if total_supply<=0 or total_demand<=0 then continue; end if;';
 if position(old_fragment in fn)=0 then raise exception 'Missing market supply guard'; end if; fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:='if price_value<=0 then continue; end if;'; if position(old_fragment in fn)=0 then raise exception 'Missing price guard'; end if; fn:=replace(fn,old_fragment,'null;');
 old_fragment:=$old$    select coalesce(sum(least(greatest(-pos.balance,0),greatest(coalesce(t.balance,0),0)/price_value)),0)::numeric(14,2)
      into affordable_demand
    from pg_temp.trade_zone_position pos left join fauxlore.state_treasuries t on t.state_id=pos.state_id and t.estate='Корона'
    where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance<0;$old$;
 new_fragment:='    affordable_demand:=total_demand;'; if position(old_fragment in fn)=0 then raise exception 'Missing cash affordability query'; end if; fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:=$old$    for buyer_row in
      select buyers.state_id,buyers.affordable,row_number() over(order by buyers.state_id) seq,count(*) over() total
      from (select pos.state_id,least(-pos.balance,coalesce(t.balance,0)/price_value)::numeric(14,2) affordable
        from pg_temp.trade_zone_position pos left join fauxlore.state_treasuries t on t.state_id=pos.state_id and t.estate='Корона'
        where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance<0) buyers
      where buyers.affordable>0 order by buyers.state_id$old$;
 new_fragment:=$new$    for buyer_row in select a.state_id,a.allocation affordable,a.influence buyer_influence
      from fauxlore.allocate_trade_market_demand(market_row.zone_id,market_row.resource_name,target_volume) a order by a.state_id$new$;
 if position(old_fragment in fn)=0 then raise exception 'Missing local buyer query'; end if; fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:='if buyer_row.seq=buyer_row.total then quantity_value:=least(buyer_row.affordable,buyer_remaining);else quantity_value:=least(buyer_row.affordable,round(target_volume*buyer_row.affordable/affordable_demand,2),buyer_remaining);end if;';
 if position(old_fragment in fn)=0 then raise exception 'Missing local buyer quota'; end if; fn:=replace(fn,old_fragment,'quantity_value:=least(buyer_row.affordable,buyer_remaining);');
 old_fragment:=$old$      select balance into crown_balance from fauxlore.state_treasuries where state_id=buyer_row.state_id and estate='Корона' for update;
      if crown_balance is null or crown_balance<=0 then continue; end if;
      if round(quantity_value*price_value,2)>crown_balance then quantity_value:=least(quantity_value,floor(crown_balance/price_value*100)/100); end if;
      if quantity_value<=0 then continue; end if;
      amount_value:=round(quantity_value*price_value,2);$old$;
 new_fragment:='      if quantity_value<=0 then continue; end if; amount_value:=0;'; if position(old_fragment in fn)=0 then raise exception 'Missing local buyer payment block'; end if; fn:=replace(fn,old_fragment,new_fragment);
 old_fragment:='amount_value:=round(quantity_value*price_value,2);'; if position(old_fragment in fn)=0 then raise exception 'Missing seller amount calculation'; end if; fn:=replace(fn,old_fragment,'amount_value:=0;');
 old_fragment:='if amount_value<=0 then continue; end if;'; if position(old_fragment in fn)=0 then raise exception 'Missing zero amount guard'; end if; fn:=replace(fn,old_fragment,'if quantity_value<=0 then continue; end if;');
 old_fragment:=$old$        update fauxlore.state_treasuries set balance=balance-amount_value,updated_at=now() where state_id=buyer_row.state_id and estate='Корона';
        insert into fauxlore.state_treasuries(state_id,estate,balance) values(seller_row.state_id,'Корона',0)
          on conflict(state_id,estate) do nothing;
        update fauxlore.state_treasuries set balance=balance+amount_value,updated_at=now() where state_id=seller_row.state_id and estate='Корона';
        insert into fauxlore.trade_market_settlements(year,turn,zone_id,resource_name,buyer_state_id,seller_state_id,quantity,unit_price,amount)
          values(new.year,new.turn,market_row.zone_id,market_row.resource_name,buyer_row.state_id,seller_row.state_id,quantity_value,price_value,amount_value);$old$;
 new_fragment:=$new$        insert into fauxlore.trade_market_settlements(year,turn,zone_id,resource_name,buyer_state_id,seller_state_id,quantity,unit_price,amount,buyer_influence)
          values(new.year,new.turn,market_row.zone_id,market_row.resource_name,buyer_row.state_id,seller_row.state_id,quantity_value,0,0,buyer_row.buyer_influence);$new$;
 if position(old_fragment in fn)=0 then raise exception 'Missing local market transfer'; end if;
 execute replace(fn,old_fragment,new_fragment);
end $$;
notify pgrst,'reload schema';
