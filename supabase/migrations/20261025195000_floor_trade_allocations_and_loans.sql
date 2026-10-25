-- Keep calculated resource allocations, state trade income, tolls, and loan totals whole.
do $migration$
declare fn text; changed text;
begin
  fn:=pg_get_functiondef('fauxlore.allocate_trade_market_demand(integer,text,numeric)'::regprocedure);
  changed:=replace(fn,'share_value:=round(remaining_value*buyer.weight/total_weight,2)','share_value:=floor(remaining_value*buyer.weight/total_weight)');
  changed:=replace(changed,'remaining_value>.004','remaining_value>0');
  if changed=fn then raise exception 'Could not floor market resource allocations'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.distribute_trade_zone_income_to_estates()'::regprocedure);
  changed:=replace(fn,'round(sum(local_income+export_income),2)','floor(sum(local_income+export_income))');
  changed:=replace(changed,'round(income_row.amount*0.15,2)','floor(income_row.amount*0.15)');
  changed:=replace(changed,'round(income_row.amount*0.10,2)','floor(income_row.amount*0.10)');
  changed:=replace(changed,'round(income_row.amount*0.05,2)','floor(income_row.amount*0.05)');
  changed:=replace(changed,'round(income_row.amount*0.65,2)','floor(income_row.amount*0.65)');
  if changed=fn then raise exception 'Could not floor trade income distribution'; end if;
  execute changed;

  fn:=pg_get_functiondef('fauxlore.collect_third_state_trade_toll()'::regprocedure);
  changed:=replace(fn,'round(current_received*coalesce((select toll_rate from fauxlore.trade_route_transit_policies where agreement_id=agreement.id and state_id=transit_state.state_id),5)/100,2)','floor(current_received*coalesce((select toll_rate from fauxlore.trade_route_transit_policies where agreement_id=agreement.id and state_id=transit_state.state_id),5)/100)');
  changed:=replace(changed,'round(toll_quantity*coalesce(resource_value,0),2)','floor(toll_quantity*coalesce(resource_value,0))');
  changed:=replace(changed,'round(current_received*coalesce((select toll_rate from fauxlore.trade_route_transit_policies where agreement_id=agreement.id and state_id=transit_state.state_id),5)/100,2)','floor(current_received*coalesce((select toll_rate from fauxlore.trade_route_transit_policies where agreement_id=agreement.id and state_id=transit_state.state_id),5)/100)');
  if changed<>fn then execute changed; end if;

  fn:=pg_get_functiondef('fauxlore.state_estate_loans_api(text,text,jsonb,uuid)'::regprocedure);
  changed:=replace(fn,'round(amount_value*1.05,2)','floor(amount_value*1.05)');
  if changed<>fn then execute changed; end if;
end
$migration$;
