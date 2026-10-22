-- Require real JSON numbers for all configurable market settings.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.economy_config_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$(next_config#>>'{tradeMarket,priceElasticity}')::numeric<.05$old$;
  new_fragment:=$new$jsonb_typeof(next_config#>'{tradeMarket,priceElasticity}') is distinct from 'number' or (next_config#>>'{tradeMarket,priceElasticity}')::numeric<.05$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market elasticity validation'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$(next_config#>>'{tradeMarket,minPriceMultiplier}')::numeric<.05$old$;
  new_fragment:=$new$jsonb_typeof(next_config#>'{tradeMarket,minPriceMultiplier}') is distinct from 'number' or (next_config#>>'{tradeMarket,minPriceMultiplier}')::numeric<.05$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market minimum validation'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$(next_config#>>'{tradeMarket,maxPriceMultiplier}')::numeric<=1$old$;
  new_fragment:=$new$jsonb_typeof(next_config#>'{tradeMarket,maxPriceMultiplier}') is distinct from 'number' or (next_config#>>'{tradeMarket,maxPriceMultiplier}')::numeric<=1$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate market maximum validation'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
