-- Fix: notifications.target_provinces is integer[], but seven notification
-- inserts pass a scalar integer, so the INSERT fails with
--   42804  column "target_provinces" is of type integer[] but expression is of type integer
-- Because the inserts run inside AFTER INSERT triggers and inside the action
-- functions themselves, the whole transaction is rolled back: building a
-- fortress/wall or a port fails outright, colonization and conquest too.
--
-- 20261110070000_notification_targets.sql introduced the column by rewriting
-- those INSERTs through text replacement. The array-valued sites
-- (military_orders.route, route_ids) were already int4[]; the scalar ones were
-- never wrapped, which is what this migration repairs.
--
-- Idempotent: a site that already reads array[...] is skipped, and a site whose
-- scalar fragment disappeared unexpectedly raises instead of silently doing
-- nothing.

do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch notifications outside production candidate';
  end if;
end
$guard$;

do $patch$
declare
  target record;
  definition text;
  found_count integer;
begin
  for target in
    select * from (values
      ('fauxlore.notify_garrison_project_started()',
       $m$,new.province_id,'military'$m$,
       $m$,array[new.province_id],'military'$m$, 1),

      ('fauxlore.complete_garrison_projects()',
       $m$,project_row.province_id,'military'$m$,
       $m$,array[project_row.province_id],'military'$m$, 1),

      ('fauxlore.military_start_port_construction(integer,jsonb)',
       $m$,province_key,'military'$m$,
       $m$,array[province_key],'military'$m$, 1),

      ('fauxlore.complete_military_port_projects()',
       $m$,project_row.sea_province_id,'military'$m$,
       $m$,array[project_row.sea_province_id],'military'$m$, 1),

      ('fauxlore.colonization_api(text,integer,jsonb)',
       $m$,target_key,'states'$m$,
       $m$,array[target_key],'states'$m$, 1),

      ('fauxlore.advance_colonization_missions()',
       $m$,m.province_id,'states'$m$,
       $m$,array[m.province_id],'states'$m$, 2),

      ('fauxlore.conquest_api(text,integer,jsonb)',
       $m$,target_key,'military'$m$,
       $m$,array[target_key],'military'$m$, 2)
    ) as t(sig, scalar_frag, array_frag, expected)
  loop
    select pg_get_functiondef(target.sig::regprocedure) into definition;

    if position(target.array_frag in definition) > 0 then
      raise notice 'skip %: already patched', target.sig;
      continue;
    end if;

    found_count := (length(definition) - length(replace(definition, target.scalar_frag, '')))
                   / length(target.scalar_frag);

    if found_count <> target.expected then
      raise exception 'patch %: expected % scalar site(s), found %',
        target.sig, target.expected, found_count;
    end if;

    execute replace(definition, target.scalar_frag, target.array_frag);
    raise notice 'patched %: % site(s)', target.sig, found_count;
  end loop;
end
$patch$;
