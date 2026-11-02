insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','clergy_loyalty','Лояльность Духовенства',0,'п.п.','Государство',''),
 ('constructor','Назначение','burgher_loyalty','Лояльность Горожан',0,'п.п.','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.effective_estate_loyalties(integer)'::regprocedure);
 marker:=$old$when 'Крестьяне' then fauxlore.state_permanent_modifier_total(target_state,array['peasant_loyalty'],null,null) else 0 end+influence$old$;
 replacement:=$new$when 'Крестьяне' then fauxlore.state_permanent_modifier_total(target_state,array['peasant_loyalty'],null,null) when 'Духовенство' then fauxlore.state_permanent_modifier_total(target_state,array['clergy_loyalty'],null,null) when 'Горожане' then fauxlore.state_permanent_modifier_total(target_state,array['burgher_loyalty'],null,null) else 0 end+influence$new$;
 if position(marker in fn)=0 then raise exception 'estate loyalty hook missing'; end if;execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
