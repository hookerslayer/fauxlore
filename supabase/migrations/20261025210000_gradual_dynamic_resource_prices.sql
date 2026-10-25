-- Restore fractional unit prices and move them gradually toward the current
-- supply/demand target. The price can change by at most 10% per game turn.
CREATE OR REPLACE FUNCTION fauxlore.trade_dynamic_price(
  base_value numeric, elasticity numeric, demand numeric, supply numeric
)
RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path=''
AS $function$
  SELECT CASE WHEN base_value<=0 THEN 0 ELSE round((base_value*greatest(.2,least(5,
    power(greatest(demand,0)/greatest(supply,.0001),elasticity))))::numeric,4) END
$function$;

CREATE OR REPLACE FUNCTION fauxlore.trade_step_price(
  base_value numeric, elasticity numeric, demand numeric, supply numeric,
  previous_price numeric, min_multiplier numeric DEFAULT .2, max_multiplier numeric DEFAULT 5
)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE SET search_path=''
AS $function$
DECLARE target_price numeric; current_price numeric; minimum_price numeric; maximum_price numeric;
BEGIN
  IF base_value<=0 THEN RETURN 0; END IF;
  minimum_price:=base_value*min_multiplier;
  maximum_price:=base_value*max_multiplier;
  target_price:=fauxlore.trade_dynamic_price(base_value,elasticity,demand,supply);
  current_price:=greatest(minimum_price,least(maximum_price,coalesce(nullif(previous_price,0),base_value)));
  RETURN round(greatest(minimum_price,least(maximum_price,
    current_price+greatest(-current_price*.1,least(current_price*.1,target_price-current_price)))),4);
END
$function$;
REVOKE ALL ON FUNCTION fauxlore.trade_step_price(numeric,numeric,numeric,numeric,numeric,numeric,numeric)
  FROM PUBLIC,anon,authenticated;

DO $migration$
DECLARE fn text; old_fragment text; new_fragment text;
BEGIN
  fn:=pg_get_functiondef('fauxlore.finish_trade_value_turn()'::regprocedure);
  old_fragment:=$old$trade_dynamic_price((res.r->>'value')::numeric,$old$;
  new_fragment:=$new$trade_step_price((res.r->>'value')::numeric,$new$;
  IF position(old_fragment IN fn)=0 THEN RAISE EXCEPTION 'State dynamic price call marker missing'; END IF;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$coalesce(ct.exported,0),0)),
    least(coalesce(c.amount,0)$old$;
  new_fragment:=$new$coalesce(ct.exported,0),0),
      coalesce((select previous.dynamic_price from fauxlore.trade_state_resource_turns previous
        where previous.state_id=s.state_id and previous.resource_name=s.resource_name
          and (previous.year,previous.turn)<(new.year,new.turn)
        order by previous.year desc,previous.turn desc limit 1),(res.r->>'value')::numeric),.2,5),
    least(coalesce(c.amount,0)$new$;
  IF position(old_fragment IN fn)=0 THEN RAISE EXCEPTION 'State previous price insertion marker missing'; END IF;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:=$old$trade_dynamic_price((r->>'value')::numeric,$old$;
  new_fragment:=$new$trade_step_price((r->>'value')::numeric,$new$;
  IF position(old_fragment IN fn)=0 THEN RAISE EXCEPTION 'Zone dynamic price call marker missing'; END IF;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$resource_name=rec.resource_name),0)),0,0
    from fauxlore.economy_parameters ep$old$;
  new_fragment:=$new$resource_name=rec.resource_name),0),
        coalesce((select previous.dynamic_price from fauxlore.trade_zone_resource_turns previous
          where previous.zone_id=rec.zone_id and previous.resource_name=rec.resource_name
            and (previous.year,previous.turn)<(new.year,new.turn)
          order by previous.year desc,previous.turn desc limit 1),(r->>'value')::numeric),.2,5),0,0
    from fauxlore.economy_parameters ep$new$;
  IF position(old_fragment IN fn)=0 THEN RAISE EXCEPTION 'Zone previous price insertion marker missing'; END IF;
  fn:=replace(fn,old_fragment,new_fragment);
  EXECUTE fn;

  fn:=pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure);
  old_fragment:=$old$price_value:=floor(greatest(base_value*(select (config#>>'{tradeMarket,minPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true),
      least(base_value*(select (config#>>'{tradeMarket,maxPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true),
        base_value*power(total_demand/total_supply,(select (config#>>'{tradeMarket,priceElasticity}')::numeric from fauxlore.economy_parameters where singleton=true))))::numeric);$old$;
  new_fragment:=$new$price_value:=fauxlore.trade_step_price(base_value,
      (select (config#>>'{tradeMarket,priceElasticity}')::numeric from fauxlore.economy_parameters where singleton=true),
      total_demand,total_supply,
      coalesce((select previous.dynamic_price from fauxlore.trade_zone_resource_turns previous
        where previous.zone_id=market_row.zone_id and previous.resource_name=market_row.resource_name
          and (previous.year,previous.turn)<(new.year,new.turn)
        order by previous.year desc,previous.turn desc limit 1),base_value),
      (select (config#>>'{tradeMarket,minPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true),
      (select (config#>>'{tradeMarket,maxPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true));$new$;
  IF position(old_fragment IN fn)=0 THEN RAISE EXCEPTION 'Trade market price target marker missing'; END IF;
  EXECUTE replace(fn,old_fragment,new_fragment);
END
$migration$;
