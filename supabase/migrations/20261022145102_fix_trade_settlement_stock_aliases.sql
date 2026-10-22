-- Disambiguate the stock column from the PL/pgSQL variable of the same name.
do $$
declare
  fn text;
  old_fragment text;
  new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.settle_trade_contracts_after_budget()'::regprocedure),chr(13),'');
  old_fragment:='select available into available from pg_temp.trade_turn_stock where';
  new_fragment:='select stock.available into available from pg_temp.trade_turn_stock stock where';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate trade stock select'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='update pg_temp.trade_turn_stock set available=available-sent where';
  new_fragment:='update pg_temp.trade_turn_stock stock set available=stock.available-sent where';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate trade stock update'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='insert into pg_temp.trade_turn_stock(state_id,resource_name,available) values(target_state,item->>''name'',received)'
    ||chr(10)||'          on conflict(state_id,resource_name) do update set available=pg_temp.trade_turn_stock.available+excluded.available;';
  new_fragment:='insert into pg_temp.trade_turn_stock as stock(state_id,resource_name,available) values(target_state,item->>''name'',received)'
    ||chr(10)||'          on conflict(state_id,resource_name) do update set available=stock.available+excluded.available;';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate trade stock upsert'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
