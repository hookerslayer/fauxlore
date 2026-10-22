-- Preserve proportional access to a scarce zone market instead of favoring
-- the first state ID in the buyer loop.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure),chr(13),'');
  old_fragment:=$old$select pos.state_id,least(-pos.balance,coalesce(t.balance,0)/price_value)::numeric(14,2) affordable
      from pg_temp.trade_zone_position pos left join fauxlore.state_treasuries t on t.state_id=pos.state_id and t.estate='Корона'
      where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance<0 order by pos.state_id$old$;
  new_fragment:=$new$select buyers.state_id,buyers.affordable,row_number() over(order by buyers.state_id) seq,count(*) over() total
      from (select pos.state_id,least(-pos.balance,coalesce(t.balance,0)/price_value)::numeric(14,2) affordable
        from pg_temp.trade_zone_position pos left join fauxlore.state_treasuries t on t.state_id=pos.state_id and t.estate='Корона'
        where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance<0) buyers
      where buyers.affordable>0 order by buyers.state_id$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market buyer allocation'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='quantity_value:=least(buyer_row.affordable,buyer_remaining);';
  new_fragment:='if buyer_row.seq=buyer_row.total then quantity_value:=least(buyer_row.affordable,buyer_remaining);'
    ||'else quantity_value:=least(buyer_row.affordable,round(target_volume*buyer_row.affordable/affordable_demand,2),buyer_remaining);end if;';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market buyer quantity'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
