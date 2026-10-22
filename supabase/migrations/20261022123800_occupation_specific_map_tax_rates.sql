-- Include the occupier's state-level rates in province payloads for accurate client-side estimates.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.map_payload()'::regprocedure),chr(13),'');
  old_fragment:='''occupation_color'',c.color';
  new_fragment:='''occupation_color'',c.color,''occupation_race_tax_rates'',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer=''races''),''{}''::jsonb),''occupation_religion_tax_rates'',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer=''religions''),''{}''::jsonb)';
  if position('occupation_race_tax_rates' in fn)>0 then return; end if;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate occupation color in map_payload'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;
