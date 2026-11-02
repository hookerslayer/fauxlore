do $migration$
declare fn text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 if position('modifier_key bigint;' in fn)=0 or position('where id=admin_modifiers_api.modifier_key;' in fn)=0 then raise exception 'assignment variable fix hook missing'; end if;
 fn:=replace(fn,'modifier_key bigint;','assignment_result_id bigint;');
 fn:=replace(fn,'returning id into modifier_key;','returning id into assignment_result_id;');
 fn:=replace(fn,'where id=admin_modifiers_api.modifier_key;','where id=assignment_result_id;');
 fn:=replace(fn,'''id'',modifier_key,','''id'',assignment_result_id,');
 execute fn;
end $migration$;
notify pgrst,'reload schema';
