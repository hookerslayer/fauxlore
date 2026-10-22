-- Split each buyer's cleared quantity proportionally across sellers, with a
-- deterministic final-row remainder to preserve exact quantity conservation.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure),chr(13),'');
  old_fragment:='quantity_value numeric(14,2); amount_value numeric(14,2);';
  new_fragment:='quantity_value numeric(14,2); amount_value numeric(14,2); buyer_quantity numeric(14,2); seller_pool numeric(14,2);';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market settlement variables'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='seller_remaining:=quantity_value;';
  new_fragment:='buyer_quantity:=quantity_value; seller_remaining:=buyer_quantity; select coalesce(sum(pos.balance),0) into seller_pool from pg_temp.trade_zone_position pos where pos.zone_id=market_row.zone_id and pos.resource_name=market_row.resource_name and pos.balance>0;';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market seller allocation'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='select state_id,balance amount from pg_temp.trade_zone_position';
  new_fragment:='select state_id,balance amount,row_number() over(order by state_id) seq,count(*) over() total from pg_temp.trade_zone_position';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market seller list'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='quantity_value:=least(seller_remaining,seller_row.amount);';
  new_fragment:='if seller_row.seq=seller_row.total then quantity_value:=least(seller_remaining,seller_row.amount);'
    ||'else quantity_value:=least(seller_remaining,seller_row.amount,round(buyer_quantity*seller_row.amount/nullif(seller_pool,0),2));end if;';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market seller quantity'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
