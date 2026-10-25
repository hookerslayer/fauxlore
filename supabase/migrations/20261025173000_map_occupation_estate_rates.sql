CREATE OR REPLACE FUNCTION fauxlore.map_payload()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
with s as (select (select jsonb_object_agg(key,value_json) from fauxlore._settings)||jsonb_build_object('economy_config',fauxlore.economy_config_payload()) as data),
visible as (select p.* from fauxlore.provinces p cross join s where
  (p.bbox->>0)::numeric<(s.data->'region'->>2)::numeric and (p.bbox->>2)::numeric>(s.data->'region'->>0)::numeric and
  (p.bbox->>1)::numeric<(s.data->'region'->>3)::numeric and (p.bbox->>3)::numeric>(s.data->'region'->>1)::numeric),
layers as (select v.province_id,jsonb_object_agg(v.layer,jsonb_build_object('id',c.id,'name',c.name,'color',c.color)||
  case when v.layer='states' then jsonb_build_object('crime',coalesce((select sp.crime from fauxlore.state_profiles sp where sp.state_id=c.id),0.2),'corruption',coalesce((select sp.corruption from fauxlore.state_profiles sp where sp.state_id=c.id),0.2),'estate_tax_rates',fauxlore.state_estate_tax_rates_json(c.id)) else '{}'::jsonb end) data
  from fauxlore.province_values v join visible p on p.id=v.province_id join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id group by v.province_id)
select s.data||jsonb_build_object('provinces',coalesce((select jsonb_agg(case when p.kind='sea' then to_jsonb(p)-array['province_type','population','development','taxes','production','warehouse','control','occupation','tension','has_capital_marker','has_city_marker']
  else to_jsonb(p)||jsonb_build_object('layers',coalesce(l.data,'{}'),'occupation_color',c.color,'occupation_estate_tax_rates',case when c.id is not null then fauxlore.state_estate_tax_rates_json(c.id) else null end,'occupation_crime',(select sp.crime from fauxlore.state_profiles sp where sp.state_id=c.id),'occupation_corruption',(select sp.corruption from fauxlore.state_profiles sp where sp.state_id=c.id)) end||jsonb_build_object('application_pending',exists(select 1 from fauxlore.application_provinces ap where ap.province_id=p.id)) order by p.id)
  from visible p left join layers l on l.province_id=p.id left join fauxlore.map_categories c on c.layer='states' and lower(c.name)=lower(p.occupation)),'[]'),
  'pending_application_provinces',coalesce((select jsonb_agg(ap.province_id order by ap.province_id) from fauxlore.application_provinces ap),'[]'::jsonb),
  'roads',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'type',r.type,'anchors',r.anchors,'segments',r.segments) order by r.id) from fauxlore.map_roads r where exists(select 1 from jsonb_array_elements(r.anchors) anchor join visible p on p.id=(anchor->>'province_id')::integer)),'[]'),
  'categories',coalesce((select jsonb_agg(to_jsonb(c)||case when c.layer='states' then jsonb_build_object('crime',coalesce(sp.crime,0.2),'corruption',coalesce(sp.corruption,0.2),'estate_tax_rates',fauxlore.state_estate_tax_rates_json(c.id)) else '{}'::jsonb end order by c.layer,c.id) from fauxlore.map_categories c left join fauxlore.state_profiles sp on sp.state_id=c.id and c.layer='states'),'[]'),
  'trade_routes',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'from_state_id',a.from_state_id,'to_state_id',a.to_state_id,
    'from_city_province_id',a.from_city_province_id,'to_city_province_id',a.to_city_province_id,'route_province_ids',a.route_province_ids) order by a.id)
    from fauxlore.trade_agreements a where a.status='accepted'
      and exists(select 1 from visible p where p.id=a.from_city_province_id)
      and exists(select 1 from visible p where p.id=a.to_city_province_id)),'[]'::jsonb),
  'markers',coalesce((select jsonb_agg(to_jsonb(m)||jsonb_build_object('state_name',c.name) order by m.id) from fauxlore.map_markers m join visible p on p.id=m.province_id left join fauxlore.map_categories c on c.layer=m.state_layer and c.id=m.state_id),'[]')) from s
$function$;
