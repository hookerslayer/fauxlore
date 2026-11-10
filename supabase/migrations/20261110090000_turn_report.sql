-- Снимки состояния государства на смене хода и API отчёта.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to create turn snapshots outside production candidate';
  end if;
end
$guard$;

create table if not exists fauxlore.state_turn_snapshots(
  state_id integer not null,
  year integer not null,
  turn integer not null,
  treasury numeric,
  prestige numeric,
  population bigint,
  development integer,
  created_at timestamp with time zone not null default now(),
  primary key (state_id, year, turn)
);
revoke all on fauxlore.state_turn_snapshots from public, anon, authenticated;
grant select on fauxlore.state_turn_snapshots to service_role;

create or replace function fauxlore.capture_state_turn_snapshots()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if (new.year, new.turn) = (old.year, old.turn) then return new; end if;
  insert into fauxlore.state_turn_snapshots(state_id, year, turn, treasury, prestige, population, development)
  select sp.state_id, new.year, new.turn,
    coalesce(sp.treasury, 0), coalesce(sp.prestige, 0),
    coalesce(sum(p.population), 0), coalesce(sum(p.development), 0)::integer
  from fauxlore.state_profiles sp
  left join fauxlore.province_values v on v.layer = 'states' and v.category_id = sp.state_id
  left join fauxlore.provinces p on p.id = v.province_id and p.kind = 'land'
  group by sp.state_id, sp.treasury, sp.prestige
  on conflict (state_id, year, turn) do update
    set treasury = excluded.treasury, prestige = excluded.prestige,
        population = excluded.population, development = excluded.development, created_at = now();
  return new;
end
$fn$;

drop trigger if exists zzzzzzzzzzzz_state_turn_snapshots on fauxlore.game_calendar;
create trigger zzzzzzzzzzzz_state_turn_snapshots
after update on fauxlore.game_calendar
for each row execute function fauxlore.capture_state_turn_snapshots();

-- Базовая точка для текущего хода.
insert into fauxlore.state_turn_snapshots(state_id, year, turn, treasury, prestige, population, development)
select sp.state_id, cal.year, cal.turn,
  coalesce(sp.treasury, 0), coalesce(sp.prestige, 0),
  coalesce(sum(p.population), 0), coalesce(sum(p.development), 0)::integer
from fauxlore.state_profiles sp
cross join fauxlore.game_calendar cal
left join fauxlore.province_values v on v.layer = 'states' and v.category_id = sp.state_id
left join fauxlore.provinces p on p.id = v.province_id and p.kind = 'land'
where cal.singleton
group by sp.state_id, sp.treasury, sp.prestige, cal.year, cal.turn
on conflict (state_id, year, turn) do nothing;

create or replace function fauxlore.turn_report_api(target_state integer)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  account_row fauxlore.accounts;
  year_value integer;
  turn_value integer;
  current_row jsonb;
  previous_row jsonb;
begin
  account_row := fauxlore.current_account();
  if account_row.id is null then raise sqlstate '28000' using message = 'Войдите через Google'; end if;
  if coalesce(account_row.role, '') <> 'admin' and not exists(
      select 1 from fauxlore.account_states a
      where a.account_id = account_row.id and a.layer = 'states' and a.state_id = target_state) then
    raise sqlstate '42501' using message = 'Нет доступа к государству';
  end if;
  select year, turn into year_value, turn_value from fauxlore.game_calendar where singleton = true;
  select to_jsonb(s) into current_row from fauxlore.state_turn_snapshots s
  where s.state_id = target_state order by s.year desc, s.turn desc limit 1;
  select to_jsonb(s) into previous_row from fauxlore.state_turn_snapshots s
  where s.state_id = target_state
    and (s.year, s.turn) < ((current_row->>'year')::integer, (current_row->>'turn')::integer)
  order by s.year desc, s.turn desc limit 1;
  return jsonb_build_object(
    'state_id', target_state,
    'year', year_value,
    'turn', turn_value,
    'current', current_row,
    'previous', previous_row,
    'history', coalesce((
      select jsonb_agg(to_jsonb(history) order by history.year, history.turn)
      from (
        select * from fauxlore.state_turn_snapshots s
        where s.state_id = target_state
        order by s.year desc, s.turn desc limit 20
      ) history), '[]'::jsonb),
    'events', jsonb_build_object(
      'colonization', coalesce((
        select jsonb_agg(jsonb_build_object('province', p.name, 'success', a.success, 'result', a.result) order by a.id)
        from fauxlore.colonization_attempts a
        join fauxlore.provinces p on p.id = a.province_id
        where a.state_id = target_state and a.year = year_value and a.turn = turn_value), '[]'::jsonb),
      'conquest', coalesce((
        select jsonb_agg(jsonb_build_object('province', p.name, 'success', a.success, 'result', a.final_result) order by a.id)
        from fauxlore.conquest_attempts a
        join fauxlore.provinces p on p.id = a.province_id
        where a.state_id = target_state and a.year = year_value and a.turn = turn_value), '[]'::jsonb),
      'religion', coalesce((
        select jsonb_agg(jsonb_build_object('effect', e.effect, 'delta', e.delta, 'province', p.name) order by e.id)
        from fauxlore.religion_turn_events e
        left join fauxlore.provinces p on p.id = e.target_province_id
        where e.state_id = target_state and e.game_year = year_value and e.game_turn = turn_value), '[]'::jsonb),
      'orders', coalesce((
        select jsonb_agg(jsonb_build_object('route', o.route, 'status', o.status) order by o.id)
        from fauxlore.military_orders o
        where o.state_id = target_state and o.issued_turn = turn_value), '[]'::jsonb)));
end
$fn$;

create or replace function public.turn_report_api(target_state integer)
returns jsonb
language sql
set search_path to 'pg_catalog', 'fauxlore'
as $fn$
  select fauxlore.turn_report_api(target_state);
$fn$;

grant execute on function public.turn_report_api(integer) to authenticated;
grant execute on function fauxlore.turn_report_api(integer) to authenticated;
