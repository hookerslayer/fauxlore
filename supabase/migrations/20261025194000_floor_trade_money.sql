-- Dynamic prices and trade proceeds are displayed and settled in whole G.
do $migration$
declare fn text; changed text;
begin
  fn:=pg_get_functiondef('fauxlore.trade_dynamic_price(numeric,numeric,numeric,numeric)'::regprocedure);
  changed:=replace(fn,'round((base_value * greatest(.2,least(5,power(greatest(demand,0)/greatest(supply,.0001),elasticity))))::numeric,4)','floor((base_value * greatest(.2,least(5,power(greatest(demand,0)/greatest(supply,.0001),elasticity))))::numeric)');
  if changed=fn then raise exception 'Could not floor dynamic trade price'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure);
  changed:=replace(fn,'price_value:=round(greatest(base_value*','price_value:=floor(greatest(base_value*');
  changed:=replace(changed,'::numeric,2);', '::numeric);');
  changed:=replace(changed,'round(buyer_quantity*seller_row.amount/nullif(seller_pool,0),2)','floor(buyer_quantity*seller_row.amount/nullif(seller_pool,0))');
  if changed=fn then raise exception 'Could not floor trade market amounts'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.finish_trade_value_turn()'::regprocedure);
  changed:=replace(fn,'round(sr.internal_quantity*sr.dynamic_price,2)','floor(sr.internal_quantity*sr.dynamic_price)');
  changed:=replace(changed,'round(sr.internal_quantity*sr.dynamic_price*coalesce((select internal_duty_rate from fauxlore.state_trade_policies where state_id=sr.state_id),15)/100,2)','floor(sr.internal_quantity*sr.dynamic_price*coalesce((select internal_duty_rate from fauxlore.state_trade_policies where state_id=sr.state_id),15)/100)');
  changed:=replace(changed,'round(zr.local_quantity*zr.dynamic_price,2)','floor(zr.local_quantity*zr.dynamic_price)');
  changed:=replace(changed,'round(zr.incoming*zr.dynamic_price,2)','floor(zr.incoming*zr.dynamic_price)');
  changed:=replace(changed,'round(flow.quantity*dest.dynamic_price,2)','floor(flow.quantity*dest.dynamic_price)');
  changed:=replace(changed,'round(flow.quantity*zone.dynamic_price,2)','floor(flow.quantity*zone.dynamic_price)');
  changed:=replace(changed,'round(local_value*participant.influence/total_influence,2)','floor(local_value*participant.influence/total_influence)');
  changed:=replace(changed,'round(export_value*participant.influence/total_influence,2)','floor(export_value*participant.influence/total_influence)');
  if changed=fn then raise exception 'Could not floor trade income and turnover'; end if;
  execute changed;
end
$migration$;
