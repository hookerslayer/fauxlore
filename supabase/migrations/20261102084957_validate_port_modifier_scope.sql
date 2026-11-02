do $migration$
declare fn text; marker text := $old$    if payload->>'scope'='marker' and$old$;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 if position(marker in fn)=0 then raise exception 'port validation hook missing'; end if;
 execute replace(fn,marker,$new$    if def.modifier_key='port_upkeep' and coalesce(payload->>'scope','state') not in ('state','marker') then raise sqlstate '22023' using message='Выберите все порты или конкретный порт'; end if;
    if payload->>'scope'='marker' and$new$);
end $migration$;
notify pgrst,'reload schema';
