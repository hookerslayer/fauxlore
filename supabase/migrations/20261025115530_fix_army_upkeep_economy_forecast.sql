-- Forecast upkeep from active military formations, matching turn settlement.
do $migration$
declare
  fn text;
  old_fragment text;
  new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.state_tax_rates_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$'army_upkeep_forecast',(select coalesce(sum(u.quantity*t.upkeep_per_unit),0)
        from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id where u.state_id=state_key),$old$;
  new_fragment:=$new$'army_upkeep_forecast',(select coalesce(sum(case when f.kind='mercenary' then coalesce(g.price,0) else coalesce((
        select sum(case when u.name='Копейщик' then greatest(0,fu.quantity-f.free_upkeep_quantity)*u.upkeep
          else fu.quantity*u.upkeep end)
        from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
        where fu.formation_id=f.id),0) end),0)
        from fauxlore.military_formations f left join fauxlore.mercenary_groups g on g.id=f.mercenary_group_id
        where f.state_id=state_key and f.active),$new$;
  if position(old_fragment in fn)=0 then
    raise exception 'Could not locate legacy army upkeep forecast expression';
  end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
