do $migration$
declare fn text; marker text := 'where id=modifier_key;';
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 if position(marker in fn)=0 then raise exception 'scope assignment fix hook missing'; end if;
 execute replace(fn,marker,'where id=admin_modifiers_api.modifier_key;');
end $migration$;
notify pgrst,'reload schema';
