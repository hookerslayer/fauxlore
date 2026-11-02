do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$update fauxlore.admin_modifier_assignments set target_scope=$old$;
 replacement:=$new$update fauxlore.admin_modifier_assignments set modifier_key=case when coalesce(payload->>'scope',case when province_key is null then 'state' else 'province' end)<>'state' and def.modifier_key='recruit_growth' then 'local_recruit_growth' when coalesce(payload->>'scope',case when province_key is null then 'state' else 'province' end)<>'state' and def.modifier_key='recruit_limit' then 'local_recruit_limit' else def.modifier_key end, target_scope=$new$;
 if position(marker in fn)=0 then raise exception 'scoped recruit assignment hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
update fauxlore.admin_modifier_assignments set modifier_key=case modifier_key when 'recruit_growth' then 'local_recruit_growth' else 'local_recruit_limit' end where target_scope<>'state' and modifier_key in ('recruit_growth','recruit_limit');
notify pgrst,'reload schema';
