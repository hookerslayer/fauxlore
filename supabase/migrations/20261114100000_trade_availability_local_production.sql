-- «Доступно» в торговом предложении должно учитывать локальные бонусы
-- производства (принципы правления и расу провинции), как это делает
-- торговая проекция. Раньше SQL видел только постоянные модификаторы.
create or replace function fauxlore.province_production_bonus(province_key integer, state_value integer)
returns numeric
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(
    (case when sp.principles->>'economy'='Крепостничество' then .50 else 0 end)
    +(case when sp.principles->>'economy'='Работорговля' then 1 else 0 end)
    -(case when sp.principles->>'economy'='Корсарство' then .20 else 0 end)
    +(case when sp.principles->>'structure'='Ленное право' and p.province_type='Регион' then .10 else 0 end)
    +(case when (sp.principles->>'structure'='Консорциум' or sp.principles->>'economy'='Гильдии')
             and p.province_type in ('Городская','Столичная') then .20 else 0 end)
    +(case when race.name='Дварфы' and resource.name in ('Металлы','Драгоценные металлы') then .20 else 0 end)
    +(case when race.name='Полуэльфы' and resource.name='Эфемера' then 3 else 0 end),0)
  from fauxlore.provinces p
  left join fauxlore.state_profiles sp on sp.state_id=state_value
  left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
  left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id
  left join fauxlore.province_values resv on resv.province_id=p.id and resv.layer='resources'
  left join fauxlore.map_categories resource on resource.layer='resources' and resource.id=resv.category_id
  where p.id=province_key
$function$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.trade_resource_surplus(integer,text)'::regprocedure) into definition;
  marker := $m$greatest(0,1+fauxlore.state_permanent_modifier_total(case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end,array['production','urban_production','regional_production','metal_production','ephemera_production'],p.id,resource.name))$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate production modifier expression';
  end if;
  replacement := $m$greatest(0,1+fauxlore.state_permanent_modifier_total(case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end,array['production','urban_production','regional_production','metal_production','ephemera_production'],p.id,resource.name)+fauxlore.province_production_bonus(p.id,state_value))$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
