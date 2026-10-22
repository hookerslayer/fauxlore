-- Keep price response and the safe price corridor editable with the other
-- administrator-managed economy constants.
update fauxlore.economy_parameters
set config=config||jsonb_build_object('tradeMarket',jsonb_build_object(
  'priceElasticity',0.5,'minPriceMultiplier',0.2,'maxPriceMultiplier',5)),updated_at=now()
where singleton=true and not (config?'tradeMarket');

do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.economy_config_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:='  insert into fauxlore.economy_parameter_history(account_id,before_config,after_config)';
  new_fragment:=$new$  if jsonb_typeof(next_config->'tradeMarket')<>'object' or
    (select array_agg(k order by k) from jsonb_object_keys(next_config->'tradeMarket') k)<>
      (select array_agg(k order by k) from jsonb_object_keys(old_config->'tradeMarket') k) or
    (next_config#>>'{tradeMarket,priceElasticity}')::numeric<.05 or (next_config#>>'{tradeMarket,priceElasticity}')::numeric>2 or
    (next_config#>>'{tradeMarket,minPriceMultiplier}')::numeric<.05 or (next_config#>>'{tradeMarket,minPriceMultiplier}')::numeric>=1 or
    (next_config#>>'{tradeMarket,maxPriceMultiplier}')::numeric<=1 or (next_config#>>'{tradeMarket,maxPriceMultiplier}')::numeric>10 then
    raise sqlstate '22023' using message='Параметры рынка должны задавать эластичность 0,05–2, минимум 0,05–<1 и максимум >1–10';
  end if;
  insert into fauxlore.economy_parameter_history(account_id,before_config,after_config)$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate economy configuration history insert'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  execute fn;
  old_fragment:='price_value:=round(greatest(base_value*.2,least(base_value*5,base_value*power(total_demand/total_supply,.5)))::numeric,2);';
  new_fragment:=$new$price_value:=round(greatest(base_value*(select (config#>>'{tradeMarket,minPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true),
      least(base_value*(select (config#>>'{tradeMarket,maxPriceMultiplier}')::numeric from fauxlore.economy_parameters where singleton=true),
        base_value*power(total_demand/total_supply,(select (config#>>'{tradeMarket,priceElasticity}')::numeric from fauxlore.economy_parameters where singleton=true))))::numeric,2);$new$;
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure),chr(13),'');
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market price formula'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
