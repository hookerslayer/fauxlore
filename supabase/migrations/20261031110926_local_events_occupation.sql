-- Provincial effects continue to apply when a different state occupies the land;
-- state-wide effects still follow only the legal owner.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
  old_fragment:=$old$join fauxlore.province_values v on v.layer='states' and v.province_id=e.province_id and v.category_id=target_state
    where e.ended_at is null$old$;
  new_fragment:=$new$join fauxlore.provinces ep on ep.id=e.province_id
    left join fauxlore.province_values v on v.layer='states' and v.province_id=e.province_id
    join fauxlore.map_categories target on target.layer='states' and target.id=target_state
    where e.ended_at is null and (v.category_id=target_state or
      (f.scope='province' and lower(ep.occupation)=lower(target.name)))$new$;
  if position(old_fragment in fn)=0 then raise exception 'Local event ownership fragment changed'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=pg_get_functiondef('public.local_events_api(text,jsonb)'::regprocedure);
  old_fragment:=$old$elsif action='end' then
    update fauxlore.local_events$old$;
  new_fragment:=$new$elsif action='end' then
    perform 1 from fauxlore.game_calendar where singleton for share;
    update fauxlore.local_events$new$;
  if position(old_fragment in fn)=0 then raise exception 'Local event end fragment changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $migration$;
