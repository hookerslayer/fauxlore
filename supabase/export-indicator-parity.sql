-- Read-only fixture for tools/test_indicator_parity.mjs. Save result locally,
-- never commit live game data. Includes no accounts or authentication data.
select jsonb_build_object(
  'config',(select config from fauxlore.economy_parameters where singleton),
  'politics',(select jsonb_agg(to_jsonb(g)) from fauxlore.state_group_politics g),
  'states',(select jsonb_agg(jsonb_build_object('id',s.state_id,'name',c.name,'indicators',fauxlore.state_indicators(s.state_id),
    'province_values',(select jsonb_object_agg(p.id,fauxlore.province_value_for_state(p.id,s.state_id)) from fauxlore.provinces p
      left join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
      where p.kind='land' and (v.category_id=s.state_id or lower(p.occupation)=lower(c.name)))))
    from fauxlore.state_profiles s join fauxlore.map_categories c on c.layer='states' and c.id=s.state_id),
  'provinces',(select jsonb_agg(jsonb_build_object('id',p.id,'kind',p.kind,'name',p.name,'province_type',p.province_type,
    'population',p.population,'development',p.development,'belonging',p.belonging,'trade_status',p.trade_status,'control',p.control,'occupation',p.occupation,
    'occupation_crime',occ.crime,'occupation_corruption',occ.corruption,
    'occupation_race_tax_rates',(select jsonb_object_agg(c.name,t.rate) from fauxlore.state_tax_rates t join fauxlore.map_categories c on c.layer=t.layer and c.id=t.category_id where t.state_id=oc.id and t.layer='races'),
    'occupation_religion_tax_rates',(select jsonb_object_agg(c.name,t.rate) from fauxlore.state_tax_rates t join fauxlore.map_categories c on c.layer=t.layer and c.id=t.category_id where t.state_id=oc.id and t.layer='religions'),
    'layers',(select jsonb_object_agg(v.layer,jsonb_build_object('id',c.id,'name',c.name)||case when v.layer='states' then
      fauxlore.state_population_growth(c.id)||jsonb_build_object(
        'race_tax_rates',(select jsonb_object_agg(mc.name,t.rate) from fauxlore.state_tax_rates t join fauxlore.map_categories mc on mc.layer=t.layer and mc.id=t.category_id where t.state_id=c.id and t.layer='races'),
        'religion_tax_rates',(select jsonb_object_agg(mc.name,t.rate) from fauxlore.state_tax_rates t join fauxlore.map_categories mc on mc.layer=t.layer and mc.id=t.category_id where t.state_id=c.id and t.layer='religions')) else '{}'::jsonb end)
      from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id)))
    from fauxlore.provinces p left join fauxlore.map_categories oc on oc.layer='states' and lower(oc.name)=lower(p.occupation)
    left join fauxlore.state_profiles occ on occ.state_id=oc.id
    where p.kind='land' and (p.occupation is not null or exists(select 1 from fauxlore.province_values v where v.province_id=p.id and v.layer='states')))
) fixture;
