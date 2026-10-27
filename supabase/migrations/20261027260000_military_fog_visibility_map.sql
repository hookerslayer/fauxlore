-- Return the authoritative province visibility set for the map's fog overlay.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.military_map_api()'::regprocedure),chr(13),'');
  old_fragment:='''fog_of_war'',not all_visible';
  new_fragment:='''fog_of_war'',not all_visible and cardinality(actor_states)>0,''visible_provinces'',case when all_visible or cardinality(actor_states)=0 then null else to_jsonb(visible_provinces) end';
  if position(old_fragment in fn)=0 then raise exception 'Could not add province visibility to military map snapshot'; end if;
  execute replace(fn,old_fragment,new_fragment);
end;
$migration$;
select pg_notify('pgrst','reload schema');
