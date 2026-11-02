insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values
 ('constructor','Назначение','state_stability_flat','Стабильность государства',0,'п.п.','Государство',''),
 ('constructor','Назначение','development_limit_flat','Лимит развития',0,'ур.','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.state_indicators_before_urbanization(integer)'::regprocedure);
 marker:=$old$'stability',(eb.value+(select sum(value) from group_blocks))/3$old$;
 replacement:=$new$'stability',greatest(0,least(1,(eb.value+(select sum(value) from group_blocks))/3+fauxlore.state_permanent_modifier_total(target_state,array['state_stability_flat'],null,null)))$new$;
 if position(marker in fn)=0 then raise exception 'stability calculation hook missing'; end if;fn:=replace(fn,marker,replacement);
 marker:=$old$sp.development_limit$old$;
 if position(marker in fn)=0 then raise exception 'development limit hook missing'; end if;
 fn:=replace(fn,marker,$new$greatest(0,sp.development_limit+fauxlore.state_permanent_modifier_total(target_state,array['development_limit_flat'],null,null))$new$);
 execute fn;
end $migration$;
notify pgrst,'reload schema';
