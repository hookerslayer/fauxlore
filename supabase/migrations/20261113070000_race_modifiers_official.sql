-- Постоянные модификаторы рас должны действовать только для официальной расы.
-- Ранее они включались при наличии расы в любой провинции: государство с
-- официальными Эльфами и колонией Людей получало модификаторы Людей.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch race modifiers outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure) into definition;
  marker := $m$    or (d.source_kind='race' and exists(select 1 from present_groups g where g.source_kind='races' and g.source_key=d.source_key))$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate race presence condition';
  end if;
  replacement := $m$    or (d.source_kind='race' and exists(
      select 1 from fauxlore.state_profiles sp3
      join fauxlore.map_categories c3 on c3.layer='races' and c3.id=sp3.official_race_id
      where sp3.state_id=s.state_id and c3.name=d.source_key))$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
