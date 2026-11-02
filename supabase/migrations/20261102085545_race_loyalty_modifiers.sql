insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','race_human_loyalty','Лояльность Людей',0,'п.п.','Государство',''),
 ('constructor','Назначение','race_dwarf_loyalty','Лояльность Дварфов',0,'п.п.','Государство',''),
 ('constructor','Назначение','race_elf_loyalty','Лояльность Эльфов',0,'п.п.','Государство',''),
 ('constructor','Назначение','race_halfelf_loyalty','Лояльность Полуэльфов',0,'п.п.','Государство',''),
 ('constructor','Назначение','race_beast_loyalty','Лояльность Зверолюдей',0,'п.п.','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.state_group_permanent_loyalty(integer,text,integer)'::regprocedure);
 marker:=$old$select coalesce(sum((m.value->>'value')::numeric),0)$old$;
 replacement:=$new$select coalesce(sum((m.value->>'value')::numeric),0)+case when group_kind='race' then coalesce((select fauxlore.state_permanent_modifier_total(target_state,array[case name when 'Люди' then 'race_human_loyalty' when 'Дварфы' then 'race_dwarf_loyalty' when 'Эльфы' then 'race_elf_loyalty' when 'Полуэльфы' then 'race_halfelf_loyalty' when 'Зверолюди' then 'race_beast_loyalty' end],null,null) from target_group),0) else 0 end$new$;
 if position(marker in fn)=0 then raise exception 'group loyalty hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
