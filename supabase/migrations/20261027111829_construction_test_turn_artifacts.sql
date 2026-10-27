-- Test-turn rollback must also restore completed construction markers and the
-- port registry. No live test turn may be active when adding snapshot fields.
do $migration$ begin
  if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
    raise exception 'Rollback the active test turn before extending construction snapshots';
  end if;
end $migration$;

create or replace function fauxlore.capture_test_turn_port_projects()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
    'military_port_projects',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)
      from fauxlore.military_port_projects x),
    'military_port_builds',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)
      from fauxlore.military_port_builds x),
    'construction_markers',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)
      from fauxlore.map_markers x where x.type in ('fortress','port')));
  return new;
end
$function$;
revoke all on function fauxlore.capture_test_turn_port_projects() from public,anon,authenticated;

create or replace function fauxlore.restore_test_turn_port_projects()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if jsonb_typeof(old.payload->'military_port_projects') is distinct from 'array'
    or jsonb_typeof(old.payload->'military_port_builds') is distinct from 'array'
    or jsonb_typeof(old.payload->'construction_markers') is distinct from 'array' then return old; end if;
  lock table fauxlore.military_port_projects,fauxlore.military_port_builds,fauxlore.map_markers in access exclusive mode;
  delete from fauxlore.military_port_builds;
  delete from fauxlore.map_markers where type in ('fortress','port');
  delete from fauxlore.military_port_projects;
  insert into fauxlore.map_markers overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.map_markers,old.payload->'construction_markers');
  insert into fauxlore.military_port_builds overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.military_port_builds,old.payload->'military_port_builds');
  insert into fauxlore.military_port_projects overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.military_port_projects,old.payload->'military_port_projects');
  return old;
end
$function$;
revoke all on function fauxlore.restore_test_turn_port_projects() from public,anon,authenticated;

notify pgrst,'reload schema';
