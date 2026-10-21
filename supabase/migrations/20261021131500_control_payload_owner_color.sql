-- Control is now numeric; derive hatch color from the province's owning state layer.
create or replace function fauxlore.province_payload(p fauxlore.provinces) returns jsonb
language sql stable security invoker set search_path='' as $$
select to_jsonb(p)||jsonb_build_object('layers',coalesce((select jsonb_object_agg(v.layer,
  jsonb_build_object('id',c.id,'name',c.name,'color',c.color))
  from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id
  where v.province_id=p.id),'{}'),
  'control_color',(select c.color from fauxlore.province_values v join fauxlore.map_categories c
    on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='states'))
$$;

create or replace function fauxlore.map_payload() returns jsonb
language sql stable security invoker set search_path='' as $$
with s as (select jsonb_object_agg(key,value_json) as data from fauxlore._settings),
visible as (select p.* from fauxlore.provinces p cross join s where
  (p.bbox->>0)::numeric<(s.data->'region'->>2)::numeric and
  (p.bbox->>2)::numeric>(s.data->'region'->>0)::numeric and
  (p.bbox->>1)::numeric<(s.data->'region'->>3)::numeric and
  (p.bbox->>3)::numeric>(s.data->'region'->>1)::numeric),
layers as (select v.province_id,jsonb_object_agg(v.layer,jsonb_build_object('id',c.id,'name',c.name,'color',c.color)) as data
  from fauxlore.province_values v join visible p on p.id=v.province_id
  join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id group by v.province_id)
select s.data||jsonb_build_object('provinces',coalesce((select jsonb_agg(case when p.kind='sea' then
  to_jsonb(p)-array['province_type','population','development','taxes','production','warehouse','control','tension','has_capital_marker','has_city_marker']
  else to_jsonb(p)||jsonb_build_object('layers',coalesce(l.data,'{}'),'control_color',c.color) end order by p.id)
  from visible p left join layers l on l.province_id=p.id
  left join fauxlore.map_categories c on c.layer='states' and c.id=(select v.category_id from fauxlore.province_values v where v.province_id=p.id and v.layer='states')),'[]'),
  'roads',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'type',r.type,'anchors',r.anchors,'segments',r.segments) order by r.id)
    from fauxlore.map_roads r where exists(select 1 from jsonb_array_elements(r.anchors) anchor join visible p on p.id=(anchor->>'province_id')::integer)),'[]'),
  'categories',coalesce((select jsonb_agg(to_jsonb(c) order by layer,id) from fauxlore.map_categories c),'[]'),
  'markers',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('state_name',c.name) order by m.id)
    from fauxlore.map_markers m join visible p on p.id=m.province_id
    left join fauxlore.map_categories c on c.layer=m.state_layer and c.id=m.state_id),'[]')) from s
$$;
