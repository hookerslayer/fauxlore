-- Сократить снимок «Военного дела»: не отдавать все морские провинции.
-- Причина: military_api('snapshot') включал все ~1065 морских провинций для
-- каждого государства (у некоторых государств — один порт). Ответ достигал
-- 1,26 МБ и собирался 3,5 с.
--
-- Оставляем морские провинции, которые реально нужны клиенту:
--   * порты, примыкающие к землям государства (список портов);
--   * провинции с активными формированиями государства;
--   * провинции незавершённых сражений.
-- Откат: восстановить определение из
-- /root/fauxlore-backups/military_api_before_sea_filter.sql

do $patch$
declare definition text; marker text; replacement text;
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch military snapshot outside production candidate';
  end if;
  select pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure) into definition;
  marker:=$m$where pv.category_id=sid or p.kind='sea' or (is_admin and p.kind='land'))$m$;
  if position(marker in definition)=0 then
    raise exception 'Could not locate military provinces filter';
  end if;
  replacement:=$m$where pv.category_id=sid or (p.kind='sea' and (
      exists(select 1 from fauxlore.military_formations f where f.state_id=sid and f.active and f.province_id=p.id)
      or exists(select 1 from fauxlore.military_battles b where b.province_id=p.id and b.status='pending')
      or exists(select 1 from fauxlore.map_markers m join fauxlore.map_adjacency a on a.singleton join lateral jsonb_array_elements_text(a.neighbors->m.province_id::text) n(value) on true join fauxlore.province_values v on v.province_id=n.value::integer and v.layer='states' and v.category_id=sid where m.province_id=p.id and m.type='port')
    )) or (is_admin and p.kind='land'))$m$;
  definition:=replace(definition,marker,replacement);
  execute definition;
end
$patch$;
