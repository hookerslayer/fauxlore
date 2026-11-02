do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
 marker:=$old$), '[]'::jsonb) from modifiers$old$;
 replacement:=$new$), '[]'::jsonb) || coalesce((select jsonb_agg(jsonb_build_object('source_kind','admin_history','source',e.source,'key','instant_'||e.effect_key,'effect',case e.effect_key when 'population' then 'Разовое изменение населения' else 'Разовое изменение развития' end,'value',e.value,'unit',case e.effect_key when 'population' then 'чел.' else 'ур.' end,'scope',p.name,'condition','','status','Применён','duration','Разовое','target_province_id',e.province_id,'target_trade_zone_id',null) order by e.created_at desc,e.id desc) from fauxlore.instant_modifier_events e join fauxlore.provinces p on p.id=e.province_id where e.state_id=target_state),'[]'::jsonb) from modifiers$new$;
 if position(marker in fn)=0 then raise exception 'instant history projection hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
