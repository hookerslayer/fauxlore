-- Проверка эффектов Астроизма. Выполняется в транзакции и откатывается.
-- Запуск: psql -v ON_ERROR_STOP=1 -f test_astroism_turn_effects.sql
begin;

do $test$
declare
  neighbors integer;
  before_treasury numeric;
  after_treasury numeric;
  buckets numeric;
  events integer;
  notifications integer;
  before_prestige numeric;
begin
  select count(*) into neighbors from fauxlore.states_within_radius(6, 6);
  if neighbors < 2 then
    raise exception 'states_within_radius(6,6) returned % states', neighbors;
  end if;

  select treasury, prestige into before_treasury, before_prestige
  from fauxlore.state_profiles where state_id = 6;

  perform fauxlore.apply_astroism_turn_effects(1454, 99, true);

  select count(*) into events from fauxlore.religion_turn_events where game_turn = 99;
  if events = 0 then
    raise exception 'Astroism effects produced no events';
  end if;

  select count(*) into notifications from fauxlore.notifications where kind = 'religion_astroism';
  if notifications = 0 then
    raise exception 'Astroism effects produced no notifications';
  end if;

  select treasury into after_treasury from fauxlore.state_profiles where state_id = 6;
  select coalesce(sum(balance), 0) into buckets from fauxlore.state_treasuries where state_id = 6;
  if after_treasury <> buckets then
    raise exception 'treasury mismatch: profile % vs buckets %', after_treasury, buckets;
  end if;
end
$test$;

rollback;
