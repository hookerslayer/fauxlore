-- Internal market and trade-zone income bonuses are reflected in the persisted
-- ledger before the Crown/estate allocations, so all recipients see the same
-- amplified turnover and the tariff remains its configured share.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.finish_trade_value_turn()'::regprocedure);
  marker:='turnover=floor(sr.internal_quantity*sr.dynamic_price),';
  replacement:='turnover=floor(sr.internal_quantity*sr.dynamic_price*greatest(0,1+fauxlore.state_permanent_modifier_total(sr.state_id,array[''internal_trade_income''],null,null))),';
  if position(marker in fn)=0 then raise exception 'Internal turnover modifier insertion point missing'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='duty_income=floor(sr.internal_quantity*sr.dynamic_price*';
  replacement:='duty_income=floor(sr.internal_quantity*sr.dynamic_price*greatest(0,1+fauxlore.state_permanent_modifier_total(sr.state_id,array[''internal_trade_income''],null,null))*';
  if position(marker in fn)=0 then raise exception 'Internal duty modifier insertion point missing'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='  -- Money is created only for the levy and each zone''s fulfilled turnover.';
  replacement:='  update fauxlore.trade_zone_income_turns zi set'||chr(10)||
    '    local_income=floor(zi.local_income*greatest(0,1+fauxlore.state_permanent_modifier_total(zi.state_id,array[''trade_zone_income''],null,null))),'||chr(10)||
    '    export_income=floor(zi.export_income*greatest(0,1+fauxlore.state_permanent_modifier_total(zi.state_id,array[''trade_zone_income''],null,null)))'||chr(10)||
    '  where zi.year=new.year and zi.turn=new.turn;'||chr(10)||marker;
  if position(marker in fn)=0 then raise exception 'Trade zone income modifier insertion point missing'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

notify pgrst,'reload schema';
