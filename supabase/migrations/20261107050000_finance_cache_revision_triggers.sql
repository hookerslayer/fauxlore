-- Ревизия должна меняться при изменении казначейств и гарнизонов: они входят
-- в finance_inputs (балансы, содержание гарнизонов), который кэшируется по
-- (data_revision, live_revision).
--
-- Откат: drop trigger state_treasuries_live_revision on fauxlore.state_treasuries;
--        drop trigger garrison_sites_live_revision on fauxlore.garrison_sites;

do $migration$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to add revision triggers outside production candidate';
  end if;
  if not exists(select 1 from pg_trigger where tgname='state_treasuries_live_revision') then
    execute 'create trigger state_treasuries_live_revision after insert or update or delete on fauxlore.state_treasuries for each statement execute function fauxlore.bump_live_revision()';
  end if;
  if not exists(select 1 from pg_trigger where tgname='garrison_sites_live_revision') then
    execute 'create trigger garrison_sites_live_revision after insert or update or delete on fauxlore.garrison_sites for each statement execute function fauxlore.bump_live_revision()';
  end if;
end
$migration$;
