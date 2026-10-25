-- Merge three explicitly selected adjacent sea regions into their designated IDs.
create temporary table province_id_merge(source_id integer primary key, target_id integer not null) on commit drop;
insert into province_id_merge(source_id,target_id) values
  (187,195),(4113,4138),(2886,2771);

-- Move province-scoped records before removing the retired province rows.
update fauxlore.application_provinces a set province_id=m.target_id from province_id_merge m where a.province_id=m.source_id;
update fauxlore.map_markers a set province_id=m.target_id from province_id_merge m where a.province_id=m.source_id;
update fauxlore.province_values a set province_id=m.target_id from province_id_merge m where a.province_id=m.source_id;
update fauxlore.state_profiles a set capital_province_id=m.target_id from province_id_merge m where a.capital_province_id=m.source_id;
update fauxlore.trade_agreements a set
  from_city_province_id=coalesce((select m.target_id from province_id_merge m where m.source_id=a.from_city_province_id),a.from_city_province_id),
  to_city_province_id=coalesce((select m.target_id from province_id_merge m where m.source_id=a.to_city_province_id),a.to_city_province_id),
  route_province_ids=array_replace(array_replace(array_replace(a.route_province_ids,187,195),4113,4138),2886,2771)
where a.route_province_ids && array[187,195,4113,4138,2886,2771]
   or a.from_city_province_id in (187,4113,2886) or a.to_city_province_id in (187,4113,2886);
update fauxlore.map_roads r set anchors=(
  select coalesce(jsonb_agg(case when m.source_id is null then anchor.value
    else jsonb_set(anchor.value,'{province_id}',to_jsonb(m.target_id)) end order by anchor.ordinality),'[]'::jsonb)
  from jsonb_array_elements(r.anchors) with ordinality anchor(value,ordinality)
  left join province_id_merge m on m.source_id=(anchor.value->>'province_id')::integer
) where exists(select 1 from jsonb_array_elements(r.anchors) anchor(value)
  join province_id_merge m on m.source_id=(anchor.value->>'province_id')::integer);

-- Replace survivor geometry with the exact union bounds and area from the rebuilt ID raster.
update fauxlore.provinces p set
  center=jsonb_build_array(g.center_x,g.center_y),
  bbox=jsonb_build_array(g.min_x,g.min_y,g.max_x,g.max_y),
  area=g.area,seed_area=g.seed_area
from (values
  (195,2743.91::numeric,3086.18::numeric,2710,3036,2780,3136,3725,3438),
  (4138,4148.03::numeric,5169.12::numeric,4090,5084,4206,5246,9294,8869),
  (2771,2948.67::numeric,4336.27::numeric,2908,4294,3014,4372,4312,4105)
) as g(id,center_x,center_y,min_x,min_y,max_x,max_y,area,seed_area)
where p.id=g.id;
delete from fauxlore.provinces p using province_id_merge m where p.id=m.source_id;

-- Remap and union adjacency lists, dropping the now-internal edges between each merged pair.
with current as (select neighbors from fauxlore.map_adjacency where singleton=true),
keys as (
  select distinct coalesce(m.target_id,k.value::integer) as node_id
  from current c cross join lateral jsonb_object_keys(c.neighbors) k(value)
  left join province_id_merge m on m.source_id=k.value::integer
),
edges as (
  select coalesce(source_map.target_id,e.key::integer) as source_id,
    coalesce(target_map.target_id,n.value::integer) as neighbor_id
  from current c cross join lateral jsonb_each(c.neighbors) e(key,neighbors)
  cross join lateral jsonb_array_elements_text(e.neighbors) n(value)
  left join province_id_merge source_map on source_map.source_id=e.key::integer
  left join province_id_merge target_map on target_map.source_id=n.value::integer
),
grouped as (
  select source_id,array_agg(distinct neighbor_id order by neighbor_id) as neighbor_ids
  from edges where source_id<>neighbor_id group by source_id
),
rebuilt as (
  select jsonb_object_agg(k.node_id::text,coalesce(to_jsonb(g.neighbor_ids),'[]'::jsonb)) as neighbors
  from keys k left join grouped g on g.source_id=k.node_id
)
update fauxlore.map_adjacency a set neighbors=r.neighbors from rebuilt r where a.singleton=true;

-- Force clients to fetch the newly rebuilt raster tiles and geometry.
update fauxlore._settings set value_json=to_jsonb(md5(clock_timestamp()::text||random()::text)) where key='tile_revision';
