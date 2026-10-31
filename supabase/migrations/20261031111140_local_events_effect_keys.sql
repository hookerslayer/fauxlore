-- Province recruitment has dedicated server keys; labels describe the effect,
-- not the race from which a catalogue definition happened to originate.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('public.local_events_api(text,jsonb)'::regprocedure);
  old_fragment:=$old$select distinct modifier_key,effect,unit from fauxlore.permanent_modifier_definitions$old$;
  new_fragment:=$new$select distinct modifier_key,case when modifier_key='population_growth' then 'Прирост населения' else effect end effect,unit from fauxlore.permanent_modifier_definitions$new$;
  if position(old_fragment in fn)=0 then raise exception 'Event catalogue fragment changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$select d.modifier_key,d.effect,d.unit into def from fauxlore.permanent_modifier_definitions d
        where d.modifier_key=row_value->>'key' and d.effect=row_value->>'effect' and d.unit=row_value->>'unit'$old$;
  new_fragment:=$new$select d.modifier_key,case when d.modifier_key='population_growth' then 'Прирост населения' else d.effect end effect,d.unit into def from fauxlore.permanent_modifier_definitions d
        where d.modifier_key=row_value->>'key' and (case when d.modifier_key='population_growth' then 'Прирост населения' else d.effect end)=row_value->>'effect' and d.unit=row_value->>'unit'$new$;
  if position(old_fragment in fn)=0 then raise exception 'Event definition fragment changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:=$old$values(event_key,scope_value,def.modifier_key,def.effect,def.unit,value_number)$old$;
  new_fragment:=$new$values(event_key,scope_value,case when scope_value='province' and def.modifier_key='recruit_growth' then 'local_recruit_growth' when scope_value='province' and def.modifier_key='recruit_limit' then 'local_recruit_limit' else def.modifier_key end,def.effect,def.unit,value_number)$new$;
  if position(old_fragment in fn)=0 then raise exception 'Event effect insertion fragment changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $migration$;

update fauxlore.local_event_effects set modifier_key=case modifier_key
  when 'recruit_growth' then 'local_recruit_growth' else 'local_recruit_limit' end
  where scope='province' and modifier_key in ('recruit_growth','recruit_limit');
update fauxlore.local_event_effects set effect='Прирост населения' where modifier_key='population_growth';
