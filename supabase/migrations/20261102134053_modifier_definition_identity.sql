do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$order by d.effect,d.source_kind,d.source_key,d.modifier_key,d.scope,d.condition_text offset definition_index limit 1;$old$;
 if position(marker in fn)=0 then raise exception 'modifier catalog selection missing';end if;
 fn:=replace(fn,marker,marker||$new$
 if payload ? 'definition_key' and payload->>'definition_key' is distinct from def.modifier_key then
  raise sqlstate '22023' using message='Каталог модификаторов изменился. Обновите страницу и повторите назначение';end if;$new$);execute fn;
end $migration$;
