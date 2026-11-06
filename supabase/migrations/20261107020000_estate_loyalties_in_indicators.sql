-- Отдавать лояльность сословий в state_indicators.
-- Причина: вкладка «Экономика» запрашивала отдельную politics-проекцию
-- (~1,6 с, сериализуется с finance-проекцией) только чтобы показать лояльность.
-- Значения уже вычисляются внутри state_indicators как cached_loyalties.
--
-- Откат: убрать из jsonb_build_object ключ 'estate_loyalties'.

do $patch$
declare definition text; marker text; replacement text;
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch indicators outside production candidate';
  end if;
  select pg_get_functiondef('fauxlore.state_indicators(integer)'::regprocedure) into definition;
  marker:=$m$'permanent_modifiers',fauxlore.state_modifiers_display_cached_loyalties(target_state,cache.value))$m$;
  if position(marker in definition)=0 then raise exception 'Could not locate indicator payload'; end if;
  replacement:=$m$'permanent_modifiers',fauxlore.state_modifiers_display_cached_loyalties(target_state,cache.value),'estate_loyalties',cache.value)$m$;
  definition:=replace(definition,marker,replacement);
  execute definition;
end
$patch$;
