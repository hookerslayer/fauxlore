-- Аудит религий: исправления.
-- 1. У Атомизма в базе был лишний +1 престижа, которого нет в правилах.
-- 2. Государственные эффекты религии включались при наличии религии в любой
--    провинции; должны действовать только для официальной религии государства.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch religion definitions outside production candidate';
  end if;
end
$guard$;

delete from fauxlore.permanent_modifier_definitions
where source_kind = 'religion' and source_key = 'Атомизм' and modifier_key = 'prestige';

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure) into definition;
  marker := $m$    or (d.source_kind in ('race','religion') and exists(select 1 from present_groups g where g.source_kind=d.source_kind||'s' and g.source_key=d.source_key))$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate religion presence condition';
  end if;
  replacement := $m$    or (d.source_kind='race' and exists(select 1 from present_groups g where g.source_kind='races' and g.source_key=d.source_key))
    or (d.source_kind='religion' and exists(
      select 1 from fauxlore.state_profiles sp2
      join fauxlore.map_categories c2 on c2.layer='religions' and c2.id=sp2.official_religion_id
      where sp2.state_id=s.state_id and c2.name=d.source_key))$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
