-- Apply action-cost modifiers to political, succession and marriage actions.
do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.group_status_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$m$cost:=case when a.role='admin' then 0 else 10 end;$m$;
  replacement:=$m$cost:=case when a.role='admin' then 0 else fauxlore.permanent_prestige_action_cost(sid,10) end;$m$;
  if position(marker in definition)=0 then raise exception 'Status-change action cost not found'; end if;
  execute replace(definition,marker,replacement);

  select pg_get_functiondef('fauxlore.character_lifecycle_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  definition:=replace(definition,'state_row.prestige<10','state_row.prestige<fauxlore.permanent_prestige_action_cost(state_value,10)');
  marker:=$m$update fauxlore.state_profiles set prestige=prestige-10 where state_id=state_value;$m$;
  replacement:=$m$update fauxlore.state_profiles set prestige=prestige-fauxlore.permanent_prestige_action_cost(state_value,10) where state_id=state_value;$m$;
  if position(marker in definition)=0 then raise exception 'Local marriage prestige payment not found'; end if;
  definition:=replace(definition,marker,replacement);
  definition:=replace(definition,'''cost'',10','''cost'',fauxlore.permanent_prestige_action_cost(state_value,10)');
  execute definition;

  select pg_get_functiondef('fauxlore.marriage_dissolution_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$m$cost_value:=case when marriage_row.marriage_type='dynastic' then 5 else 0 end;$m$;
  replacement:=$m$cost_value:=case when marriage_row.marriage_type='dynastic' then fauxlore.permanent_prestige_action_cost(state_value,5) else 0 end;$m$;
  if position(marker in definition)=0 then raise exception 'Marriage dissolution cost not found'; end if;
  execute replace(definition,marker,replacement);

  select pg_get_functiondef('fauxlore.succession_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$m$coalesce(sp.prestige,0)<15$m$;
  replacement:=$m$coalesce(sp.prestige,0)<fauxlore.permanent_prestige_action_cost(state_value,15)$m$;
  if position(marker in definition)=0 then raise exception 'Heir designation prestige check not found'; end if;
  definition:=replace(definition,marker,replacement);
  marker:=$m$prestige=prestige-15 where state_id=state_value$m$;
  replacement:=$m$prestige=prestige-fauxlore.permanent_prestige_action_cost(state_value,15) where state_id=state_value$m$;
  if position(marker in definition)=0 then raise exception 'Heir designation prestige payment not found'; end if;
  execute replace(definition,marker,replacement);
end
$patch$;
notify pgrst,'reload schema';
