-- Resource values may be configured as zero (for non-commercial resources).
-- Skip such a market before dividing by its rounded unit price.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure),chr(13),'');
  old_fragment:='    select coalesce(sum(least(greatest(-pos.balance,0),greatest(coalesce(t.balance,0),0)/price_value)),0)::numeric(14,2)';
  new_fragment:='    if price_value<=0 then continue; end if;'||chr(10)||old_fragment;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate affordability calculation'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
