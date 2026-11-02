do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
 marker:=$old$      perform fauxlore.admin_modifiers_api('assign',effect_payload);$old$;
 replacement:=$new$      if item ? 'resource' then
        perform fauxlore.admin_modifiers_api('resource_assign',item||jsonb_build_object('state_id',verdict_state));
      else
        perform fauxlore.admin_modifiers_api('assign',effect_payload);
      end if;$new$;
 if position(marker in fn)=0 then raise exception 'wall modifier hook missing'; end if; execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.wall_verdict_many(jsonb)'::regprocedure);
 marker:=$old$      perform fauxlore.admin_modifiers_api('assign',item||jsonb_build_object('state_id',sid,'target_kind','state','province_id',null));$old$;
 replacement:=$new$      if item ? 'resource' then
        perform fauxlore.admin_modifiers_api('resource_assign',item||jsonb_build_object('state_id',sid));
      else
        perform fauxlore.admin_modifiers_api('assign',item||jsonb_build_object('state_id',sid,'target_kind','state','province_id',null));
      end if;$new$;
 if position(marker in fn)=0 then raise exception 'multi-state modifier hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
