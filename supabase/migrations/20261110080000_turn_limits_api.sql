-- Сводка лимитов текущего хода для государства (колонизации и завоевания).
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to create turn limits API outside production candidate';
  end if;
end
$guard$;

create or replace function fauxlore.turn_limits_api(target_state integer)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  account_row fauxlore.accounts;
  year_value integer;
  turn_value integer;
  colonization_used integer;
  conquest_used integer;
begin
  account_row := fauxlore.current_account();
  if account_row.id is null then raise sqlstate '28000' using message = 'Войдите через Google'; end if;
  if coalesce(account_row.role, '') <> 'admin' and not exists(
      select 1 from fauxlore.account_states a
      where a.account_id = account_row.id and a.layer = 'states' and a.state_id = target_state) then
    raise sqlstate '42501' using message = 'Нет доступа к государству';
  end if;
  select year, turn into year_value, turn_value from fauxlore.game_calendar where singleton = true;
  select count(*) into colonization_used from fauxlore.colonization_attempts
  where state_id = target_state and year = year_value and turn = turn_value;
  select count(*) into conquest_used from fauxlore.conquest_attempts
  where state_id = target_state and year = year_value and turn = turn_value;
  return jsonb_build_object(
    'year', year_value,
    'turn', turn_value,
    'colonization', jsonb_build_object('used', colonization_used, 'limit', 2),
    'conquest', jsonb_build_object('used', conquest_used, 'limit', 2));
end
$fn$;

create or replace function public.turn_limits_api(target_state integer)
returns jsonb
language sql
set search_path to 'pg_catalog', 'fauxlore'
as $fn$
  select fauxlore.turn_limits_api(target_state);
$fn$;

grant execute on function public.turn_limits_api(integer) to authenticated;
grant execute on function fauxlore.turn_limits_api(integer) to authenticated;
