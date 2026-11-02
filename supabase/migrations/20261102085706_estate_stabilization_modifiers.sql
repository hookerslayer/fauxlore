insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','nobility_stabilization','Стабилизация Знати',0,'п.п.','Государство',''),
 ('constructor','Назначение','clergy_stabilization','Стабилизация Духовенства',0,'п.п.','Государство',''),
 ('constructor','Назначение','burgher_stabilization','Стабилизация Горожан',0,'п.п.','Государство',''),
 ('constructor','Назначение','peasant_stabilization','Стабилизация Крестьян',0,'п.п.','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
 marker:=$old$case status when 'Ключевое' then 1.5 when 'Значимое' then 1 when 'Бесправное' then .25 else 0 end))) value from loyalties$old$;
 replacement:=$new$case status when 'Ключевое' then 1.5 when 'Значимое' then 1 when 'Бесправное' then .25 else 0 end+fauxlore.state_permanent_modifier_total(target_state,array[case name when 'Знать' then 'nobility_stabilization' when 'Духовенство' then 'clergy_stabilization' when 'Горожане' then 'burgher_stabilization' when 'Крестьяне' then 'peasant_stabilization' end],null,null)))) value from loyalties$new$;
 if position(marker in fn)=0 then raise exception 'estate stabilization hook missing'; end if;execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
