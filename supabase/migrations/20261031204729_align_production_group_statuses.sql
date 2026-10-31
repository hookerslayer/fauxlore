-- Use the same race/religion status factors as the province projection and
-- food report when deriving supply and the resource-turn report.
do $migration$
declare fn text; marker text; proc regprocedure;
  controller text:=$s$case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end$s$;
  factors text;
begin
  factors:='*coalesce(fauxlore.group_status_effect('||controller||',''race'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''races''),''production''),1)'
    ||'*coalesce(fauxlore.group_status_effect('||controller||',''religion'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),''production''),1)';
  foreach proc in array array['fauxlore.clear_trade_zones_after_budget()'::regprocedure,'fauxlore.trade_resource_surplus(integer,text)'::regprocedure,'fauxlore.finish_trade_value_turn()'::regprocedure] loop
    fn:=pg_get_functiondef(proc);
    marker:=$s$coalesce(p.control,100)::numeric/100*greatest(0,coalesce(p.development,100))::numeric/100$s$;
    if position(marker in fn)=0 then raise exception 'Production group status marker changed in %',proc; end if;
    execute replace(fn,marker,marker||factors);
  end loop;
end $migration$;
