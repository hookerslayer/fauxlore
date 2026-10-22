-- Expose the currently configured recurring army upkeep to each state's
-- authorized tax/economy view so the client can show a next-turn forecast.
do $$
declare
  fn text;
  old_fragment text;
  new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.state_tax_rates_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$'groups',coalesce((select jsonb_agg(jsonb_build_object('layer',l.layer,'id',c.id,'name',c.name,$old$;
  new_fragment:=$new$'army_upkeep_forecast',(select coalesce(sum(u.quantity*t.upkeep_per_unit),0)
        from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id where u.state_id=state_key),
      'groups',coalesce((select jsonb_agg(jsonb_build_object('layer',l.layer,'id',c.id,'name',c.name,$new$;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate state tax rates forecast insertion point'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
