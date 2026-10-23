do $$
declare fn text; marker text:='production_value:=round(population*resource_prod*prod_mod*control_value*(1-crime_rate)*share,0);';
begin
  fn:=pg_get_functiondef('fauxlore.province_value_for_state(integer,integer)'::regprocedure);
  if position(marker in fn)=0 then raise exception 'Province production valuation marker missing'; end if;
  fn:=replace(fn,marker,'production_value:=round(population*resource_prod*prod_mod*control_value*(1-crime_rate)*share*'||
    'fauxlore.group_status_effect(target_state,''race'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''races''),''production'')*'||
    'fauxlore.group_status_effect(target_state,''religion'',(select category_id from fauxlore.province_values where province_id=p.id and layer=''religions''),''production''),0);');
  execute fn;
end $$;
notify pgrst,'reload schema';
