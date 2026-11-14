-- Местность хранится в provinces.terrain_type, а не в province_values.
-- Из-за этого условия «Эльфы + Лес» и «Полуэльфы + Лес» никогда не срабатывали.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch modifier conditions outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure) into definition;
  marker := $m$      if scope_value like '%+ Лес' and not exists(select 1 from fauxlore.province_values terrain_v
        join fauxlore.map_categories terrain on terrain.layer='terrain_type' and terrain.id=terrain_v.category_id
        where terrain_v.province_id=target_province and terrain.name='Лес') then continue; end if;$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate terrain condition';
  end if;
  replacement := $m$      if scope_value like '%+ Лес' and not exists(select 1 from fauxlore.provinces terrain_province
        where terrain_province.id=target_province and terrain_province.terrain_type='forest') then continue; end if;$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
