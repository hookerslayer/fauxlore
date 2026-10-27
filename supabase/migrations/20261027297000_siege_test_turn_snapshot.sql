-- Include siege state in the existing reversible test-turn snapshots.
create or replace function fauxlore.capture_test_turn_sieges()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object('military_sieges',
    (select coalesce(jsonb_agg(to_jsonb(s) order by s.id),'[]'::jsonb) from fauxlore.military_sieges s));
  return new;
end
$function$;
revoke all on function fauxlore.capture_test_turn_sieges() from public,anon,authenticated;
create trigger turn_test_snapshot_capture_sieges before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_sieges();

create or replace function fauxlore.restore_test_turn_sieges()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if old.after_revision is null or jsonb_typeof(old.payload->'military_sieges')<>'array' then return old; end if;
  lock table fauxlore.military_sieges in access exclusive mode;
  delete from fauxlore.military_sieges where true;
  insert into fauxlore.military_sieges overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.military_sieges,old.payload->'military_sieges');
  perform setval(pg_get_serial_sequence('fauxlore.military_sieges','id'),
    coalesce((select max(id) from fauxlore.military_sieges),1),exists(select 1 from fauxlore.military_sieges));
  return old;
end
$function$;
revoke all on function fauxlore.restore_test_turn_sieges() from public,anon,authenticated;
create trigger turn_test_snapshot_restore_sieges before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_sieges();
