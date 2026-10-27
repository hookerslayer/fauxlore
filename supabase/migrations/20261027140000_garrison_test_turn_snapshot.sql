-- The test-turn snapshot must cover fort completion and maintenance, including
-- the payer introduced by estate sponsorship.
do $$ begin
 if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
   raise exception 'Rollback the active test turn before extending garrison snapshot'; end if;
end $$;

create or replace function fauxlore.capture_test_turn_garrisons()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
   'garrison_sites',(select coalesce(jsonb_agg(to_jsonb(x) order by province_id),'[]'::jsonb) from fauxlore.garrison_sites x),
   'garrison_units',(select coalesce(jsonb_agg(to_jsonb(x) order by province_id,unit_id),'[]'::jsonb) from fauxlore.garrison_units x),
   'garrison_projects',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb) from fauxlore.garrison_projects x),
   'garrison_charges',(select coalesce(jsonb_agg(to_jsonb(x) order by state_id,year,turn),'[]'::jsonb) from fauxlore.garrison_charges x));
 return new;
end $function$;
revoke all on function fauxlore.capture_test_turn_garrisons() from public,anon,authenticated;
create trigger turn_test_snapshot_capture_garrisons before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_garrisons();

create or replace function fauxlore.restore_test_turn_garrisons()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 if old.after_revision is null or jsonb_typeof(old.payload->'garrison_sites')<>'array' then return old; end if;
 lock table fauxlore.garrison_sites,fauxlore.garrison_units,fauxlore.garrison_projects,
   fauxlore.garrison_charges in access exclusive mode;
 delete from fauxlore.garrison_charges where true;
 delete from fauxlore.garrison_sites where true;
 insert into fauxlore.garrison_sites
   select * from jsonb_populate_recordset(null::fauxlore.garrison_sites,old.payload->'garrison_sites');
 insert into fauxlore.garrison_units
   select * from jsonb_populate_recordset(null::fauxlore.garrison_units,old.payload->'garrison_units');
 insert into fauxlore.garrison_projects overriding system value
   select * from jsonb_populate_recordset(null::fauxlore.garrison_projects,old.payload->'garrison_projects');
 insert into fauxlore.garrison_charges
   select * from jsonb_populate_recordset(null::fauxlore.garrison_charges,old.payload->'garrison_charges');
 return old;
end $function$;
revoke all on function fauxlore.restore_test_turn_garrisons() from public,anon,authenticated;
create trigger turn_test_snapshot_restore_garrisons before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_garrisons();
