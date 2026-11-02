do $migration$
declare fn text; marker text := $old$base.modifier_state,array['fortification_upkeep'],null,null)$old$;
begin
 fn:=pg_get_functiondef('fauxlore.garrison_site_upkeep(integer)'::regprocedure);
 if position(marker in fn)=0 then raise exception 'fortification upkeep hook missing'; end if;
 execute replace(fn,marker,$new$base.modifier_state,array['fortification_upkeep'],base.province_id,null)$new$);
end $migration$;
notify pgrst,'reload schema';
