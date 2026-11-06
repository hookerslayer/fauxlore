-- Ревизия должна меняться при изменении налоговых ставок и колонизационных
-- миссий: обе таблицы входят в projection_source, который кэшируется по
-- (data_revision, live_revision). Без триггеров кэш мог бы отдать устаревшие
-- ставки или миссии до следующего изменения карты.
--
-- Откат: drop trigger state_estate_tax_rates_live_revision on fauxlore.state_estate_tax_rates;
--        drop trigger colonization_missions_live_revision on fauxlore.colonization_missions;

do $migration$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to add revision triggers outside production candidate';
  end if;
  if not exists(select 1 from pg_trigger where tgname='state_estate_tax_rates_live_revision') then
    execute 'create trigger state_estate_tax_rates_live_revision after insert or update or delete on fauxlore.state_estate_tax_rates for each statement execute function fauxlore.bump_live_revision()';
  end if;
  if not exists(select 1 from pg_trigger where tgname='colonization_missions_live_revision') then
    execute 'create trigger colonization_missions_live_revision after insert or update or delete on fauxlore.colonization_missions for each statement execute function fauxlore.bump_live_revision()';
  end if;
end
$migration$;
