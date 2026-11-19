-- Лимит развития: базовое значение и сумма модификаторов.
-- Вкладка «Обзор» показывает действующий лимит (база + модификаторы), но форма
-- администратора раньше подставляла именно действующее значение и сохраняла его
-- как базовое. При активных модификаторах это записывало их в базу и эффект
-- применялся дважды. Возвращаем оба значения, чтобы форма редактировала базу.
do $migration$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.state_indicators_base_cached_loyalties(integer,jsonb)'::regprocedure);
  if position('development_limit_base' in definition)=0 then
    marker:=$m$'missing_development_count',a.missing_development,'development_limit',greatest(0,sp.development_limit+fauxlore.state_permanent_modifier_total(target_state,array['development_limit_flat'],null,null))$m$;
    if position(marker in definition)=0 then raise exception 'Development limit projection changed'; end if;
    definition:=replace(definition,marker,
      $m$'missing_development_count',a.missing_development,
  'development_limit_base',sp.development_limit,
  'development_limit_modifier',fauxlore.state_permanent_modifier_total(target_state,array['development_limit_flat'],null,null),
  'development_limit',greatest(0,sp.development_limit+fauxlore.state_permanent_modifier_total(target_state,array['development_limit_flat'],null,null))$m$);
    execute definition;
  end if;
end $migration$;

-- Ответ на изменение лимита тоже различает базу и действующее значение.
do $migration$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.state_indicators_api(text,text,jsonb,uuid)'::regprocedure);
  if position('development_limit_base' in definition)=0 then
    marker:=$m$'development_limit_before',development_limit,'development_limit',limit_value$m$;
    if position(marker in definition)=0 then raise exception 'Development limit PATCH result changed'; end if;
    definition:=replace(definition,marker,
      $m$'development_limit_before',development_limit,'development_limit',limit_value,'development_limit_base',limit_value,
      'development_limit_effective',greatest(0,limit_value+fauxlore.state_permanent_modifier_total(sid,array['development_limit_flat'],null,null))$m$);
    execute definition;
  end if;
end $migration$;

notify pgrst,'reload schema';
