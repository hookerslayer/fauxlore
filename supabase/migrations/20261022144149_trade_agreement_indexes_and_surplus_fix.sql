-- Cover every trade agreement foreign key and handle occupation on unowned provinces.
create index if not exists trade_agreements_from_city_idx on fauxlore.trade_agreements(from_city_province_id);
create index if not exists trade_agreements_to_city_idx on fauxlore.trade_agreements(to_city_province_id);
create index if not exists trade_agreements_created_by_idx on fauxlore.trade_agreements(created_by);
create index if not exists trade_agreements_answered_by_idx on fauxlore.trade_agreements(answered_by);

create or replace function fauxlore.trade_resource_surplus(state_value integer,resource_value text)
returns numeric language sql stable security definer set search_path='' as $$
  with cfg as (select config from fauxlore.economy_parameters where singleton=true),
  resource_config as (select r from cfg cross join lateral jsonb_array_elements(cfg.config->'resources') r where r->>'name'=resource_value limit 1),
  owned_population as (
    select coalesce(sum(p.population),0)::numeric amount from fauxlore.provinces p
    join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states' and owner.category_id=state_value
    where p.kind='land'
  ),
  output as (
    select coalesce(sum(round(greatest(p.population,0)::numeric*(rc.r->>'production')::numeric*
      (cfg.config#>>array['provinceModifiers',p.province_type,'production'])::numeric*
      coalesce(p.control,100)::numeric/100*(1-coalesce(owner_profile.crime,.2))*
      case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,''))
        then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 1 end,0)),0)::numeric amount
    from fauxlore.provinces p
    join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='resources'
    join fauxlore.map_categories resource on resource.layer='resources' and resource.id=rv.category_id and resource.name=resource_value
    left join fauxlore.province_values owner_value on owner_value.province_id=p.id and owner_value.layer='states'
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=owner_value.category_id
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    left join fauxlore.state_profiles owner_profile on owner_profile.state_id=owner.id
    cross join cfg cross join resource_config rc
    where p.kind='land' and (case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end)=state_value
  )
  select coalesce(output.amount,0)-ceil(owned_population.amount/10*(resource_config.r->>'consumption')::numeric)
  from output cross join owned_population cross join resource_config
$$;
revoke all on function fauxlore.trade_resource_surplus(integer,text) from public,anon,authenticated;
