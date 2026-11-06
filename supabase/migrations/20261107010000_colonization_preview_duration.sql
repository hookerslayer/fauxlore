-- Показывать фактический срок колонизации (с модификаторами) в предпросмотре миссии.
-- Причина: срок считался только при завершении миссии и в списке миссий,
-- поэтому игрок не видел эффекта модификатора «Срок колонизации провинций
-- с Витализмом −1 ход» до старта и во время миссии.
--
-- Откат: убрать из jsonb_build_object ветки preview поле 'duration'.

do $patch$
declare definition text; marker text; replacement text;
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch colonization preview outside production candidate';
  end if;
  select pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure) into definition;
  marker:=$m$'recruit_bonus',recruit_bonus,'route_penalty',path_penalty,'modifiers',dice_modifiers,$m$;
  if position(marker in definition)=0 then raise exception 'Could not locate colonization preview payload'; end if;
  replacement:=marker||$m$'duration',greatest(1,4+floor(fauxlore.state_permanent_modifier_total(state_key,array['colonization_duration'],target_key,null))::integer),$m$;
  definition:=replace(definition,marker,replacement);
  execute definition;
end
$patch$;
