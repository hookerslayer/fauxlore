-- Запрет завоевания провинций с нейтральными маркерами.
-- Такие провинции защищены нейтральными силами и не могут быть завоёваны,
-- как и колонизированы.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch conquest outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.conquest_api(text,integer,jsonb)'::regprocedure) into definition;
  marker := $m$  if exists(select 1 from fauxlore.province_values v where v.province_id = target_key and v.layer = 'states') then
    raise sqlstate '22023' using message = 'Завоёвывать можно только нейтральную провинцию';
  end if;$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate conquest neutral check';
  end if;
  replacement := marker || $m$

  if exists(select 1 from fauxlore.map_markers m where m.province_id = target_key and m.state_id is null) then
    raise sqlstate '22023' using message = 'В провинции есть нейтральный маркер: её нельзя завоевать';
  end if;$m$;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
