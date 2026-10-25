-- Weight each estate's economic share by its constitutional status before
-- normalizing political influence. This is read by state indicators and turns.
do $migration$
declare
  fn text;
  old_fragment text := 'coalesce(sum(fauxlore.province_value_for_state(p.id,target_state)*ep.population/nullif(p.population,0)),0) weight,';
  new_fragment text := 'coalesce(sum(fauxlore.province_value_for_state(p.id,target_state)*ep.population/nullif(p.population,0)*case coalesce(g.status,fauxlore.estate_status_for(target_state,e.name)) when ''Ключевое'' then 3 when ''Значимое'' then 1.5 when ''Бесправное'' then .25 else 1 end),0) weight,';
begin
  fn := pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
  if position(old_fragment in fn)>0 then
    fn := replace(fn,old_fragment,new_fragment);
    execute fn;
  elsif position(new_fragment in fn)=0 then
    raise exception 'Could not find estate weight formula to update';
  end if;
end
$migration$;