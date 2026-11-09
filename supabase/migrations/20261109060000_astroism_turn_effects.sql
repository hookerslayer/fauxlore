-- Астроизм: эффекты религии при смене хода.
-- Ранее модификаторы существовали только текстом в правилах и не применялись.
--
-- Реализация:
--   * религия 4 (Астроизм);
--   * «соседние государства» — государства, чьи провинции находятся в пределах
--     6 сухопутных переходов от провинций государства Астроизма;
--   * события пишутся в fauxlore.religion_turn_events и в уведомления;
--   * триггер на game_calendar применяет эффекты при смене года/хода;
--   * apply_astroism_turn_effects(..., true) используется для догона прошлых ходов.
--
-- Откат:
--   drop trigger zzzzzzzzzz_astroism_after_turn on fauxlore.game_calendar;
--   drop function fauxlore.astroism_turn_effects_trigger();
--   drop function fauxlore.apply_astroism_turn_effects(integer,integer,boolean);
--   drop function fauxlore.states_within_radius(integer,integer);
--   drop function fauxlore.notify_state_accounts(integer,text,text,text);
--   drop table fauxlore.religion_turn_events;

do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to install Astroism effects outside production candidate';
  end if;
end
$guard$;

create table if not exists fauxlore.religion_turn_events(
  id bigserial primary key,
  religion_id integer not null,
  state_id integer not null,
  game_year integer not null,
  game_turn integer not null,
  effect text not null,
  target_state_id integer,
  target_province_id integer,
  delta numeric,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamp with time zone not null default now()
);

revoke all on fauxlore.religion_turn_events from public, anon, authenticated;
grant select on fauxlore.religion_turn_events to service_role;
grant usage on sequence fauxlore.religion_turn_events_id_seq to service_role;
create index if not exists religion_turn_events_state_turn
  on fauxlore.religion_turn_events(state_id, game_year, game_turn);

create or replace function fauxlore.notify_state_accounts(
  p_state integer, p_kind text, p_title text, p_message text)
returns void
language sql
security definer
set search_path to ''
as $fn$
  insert into fauxlore.notifications(account_id, kind, title, message)
  select recipients.account_id, p_kind, p_title, p_message
  from (
    select distinct ast.account_id
    from fauxlore.account_states ast
    where ast.layer = 'states' and ast.state_id = p_state
    union
    select ac.id from fauxlore.accounts ac where ac.role = 'admin'
  ) recipients;
$fn$;

revoke all on function fauxlore.notify_state_accounts(integer,text,text,text) from public, anon, authenticated;

-- Государства, чьи сухопутные провинции достижимы за p_radius переходов.
create or replace function fauxlore.states_within_radius(p_state integer, p_radius integer)
returns table(state_id integer)
language sql
stable
security definer
set search_path to ''
as $fn$
  with recursive owned as (
    select pv.category_id state_id, p.id province_id
    from fauxlore.provinces p
    join fauxlore.province_values pv on pv.province_id = p.id and pv.layer = 'states'
    where p.kind = 'land'
  ),
  adjacency as (
    select (entry.key)::integer pid, (neighbor.value)::integer nb
    from fauxlore.map_adjacency a
    cross join lateral jsonb_each(a.neighbors) entry
    cross join lateral jsonb_array_elements_text(entry.value) neighbor(value)
    where a.singleton
  ),
  bfs(pid, depth) as (
    select province_id, 0 from owned where state_id = p_state
    union
    select adjacency.nb, bfs.depth + 1
    from bfs join adjacency on adjacency.pid = bfs.pid
    where bfs.depth < p_radius
  )
  select distinct o.state_id
  from bfs join owned o on o.province_id = bfs.pid
  where o.state_id <> p_state;
$fn$;

revoke all on function fauxlore.states_within_radius(integer,integer) from public, anon, authenticated;

create or replace function fauxlore.apply_astroism_turn_effects(
  p_year integer, p_turn integer, p_backfill boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  religion_id constant integer := 4;
  radius constant integer := 6;
  sp record;
  nb record;
  prov record;
  cap integer;
  delta integer;
  pct numeric;
  rnd_province integer;
  owner_state integer;
  events jsonb := '[]'::jsonb;
  msg text;
  prefix text := case when p_backfill
    then 'Астроизм, восстановление за ход ' || p_turn || ': '
    else 'Астроизм: ' end;
begin
  for sp in select * from fauxlore.state_profiles where official_religion_id = religion_id loop
    -- 1. Развитие столиц соседних государств: 10% на каждую столицу.
    for nb in select s.state_id from fauxlore.states_within_radius(sp.state_id, radius) s loop
      select capital_province_id into cap from fauxlore.state_profiles where state_id = nb.state_id;
      if cap is null then continue; end if;
      if random() < 0.10 then
        delta := floor(random() * 21)::integer - 10;
        update fauxlore.provinces
          set development = greatest(0, coalesce(development, 0) + delta)
          where id = cap;
        events := events || jsonb_build_array(jsonb_build_object(
          'effect', 'neighbor_capital', 'state', sp.state_id, 'target_state', nb.state_id,
          'province', cap, 'delta', delta));
        insert into fauxlore.religion_turn_events(
          religion_id, state_id, game_year, game_turn, effect, target_state_id, target_province_id, delta, detail)
        values (religion_id, sp.state_id, p_year, p_turn, 'neighbor_capital', nb.state_id, cap, delta,
          jsonb_build_object('backfill', p_backfill));
        perform fauxlore.notify_state_accounts(nb.state_id, 'religion_astroism',
          prefix || 'знамение над столицей',
          'Столица государства «' || (select name from fauxlore.map_categories where layer = 'states' and id = nb.state_id) ||
          '» изменила развитие на ' || case when delta > 0 then '+' else '' end || delta ||
          ' ед. под влиянием астрожрецов.');
      end if;
    end loop;

    -- 2. Пять случайных провинций государства: от -2 до +5.
    msg := '';
    for prov in
      select p.id, p.name
      from fauxlore.provinces p
      join fauxlore.province_values pv on pv.province_id = p.id and pv.layer = 'states'
      where pv.category_id = sp.state_id and p.kind = 'land'
      order by random()
      limit 5
    loop
      delta := floor(random() * 8)::integer - 2;
      update fauxlore.provinces
        set development = greatest(0, coalesce(development, 0) + delta)
        where id = prov.id;
      events := events || jsonb_build_array(jsonb_build_object(
        'effect', 'province_development', 'state', sp.state_id, 'province', prov.id, 'delta', delta));
      insert into fauxlore.religion_turn_events(
        religion_id, state_id, game_year, game_turn, effect, target_state_id, target_province_id, delta, detail)
      values (religion_id, sp.state_id, p_year, p_turn, 'province_development', sp.state_id, prov.id, delta,
        jsonb_build_object('backfill', p_backfill));
      msg := msg || '«' || prov.name || '» ' || case when delta > 0 then '+' else '' end || delta || '; ';
    end loop;
    if msg <> '' then
      perform fauxlore.notify_state_accounts(sp.state_id, 'religion_astroism',
        prefix || 'звёздный расчёт',
        'Пять провинций получили изменения развития: ' || msg);
    end if;

    -- 3. Престиж: от -5 до +10.
    delta := floor(random() * 16)::integer - 5;
    update fauxlore.state_profiles
      set prestige = greatest(0, coalesce(prestige, 0) + delta)
      where state_id = sp.state_id;
    events := events || jsonb_build_array(jsonb_build_object(
      'effect', 'prestige', 'state', sp.state_id, 'delta', delta));
    insert into fauxlore.religion_turn_events(
      religion_id, state_id, game_year, game_turn, effect, target_state_id, target_province_id, delta, detail)
    values (religion_id, sp.state_id, p_year, p_turn, 'prestige', sp.state_id, null, delta,
      jsonb_build_object('backfill', p_backfill));
    perform fauxlore.notify_state_accounts(sp.state_id, 'religion_astroism',
      prefix || 'престиж', 'Престиж изменился на ' || case when delta > 0 then '+' else '' end || delta || ' ОП.');

    -- 4. Казна: от -10% до +10% текущего значения.
    pct := random() * 0.2 - 0.1;
    delta := round(coalesce(sp.treasury, 0) * pct);
    if delta <> 0 then
      update fauxlore.state_profiles
        set treasury = coalesce(treasury, 0) + delta
        where state_id = sp.state_id;
      update fauxlore.state_treasuries
        set balance = balance + delta
        where state_id = sp.state_id and estate = 'Корона';
      if not found then
        insert into fauxlore.state_treasuries(state_id, estate, balance)
        values (sp.state_id, 'Корона', delta);
      end if;
      events := events || jsonb_build_array(jsonb_build_object(
        'effect', 'treasury', 'state', sp.state_id, 'delta', delta));
      insert into fauxlore.religion_turn_events(
        religion_id, state_id, game_year, game_turn, effect, target_state_id, target_province_id, delta, detail)
      values (religion_id, sp.state_id, p_year, p_turn, 'treasury', sp.state_id, null, delta,
        jsonb_build_object('backfill', p_backfill, 'percent', round(pct * 100, 2)));
      perform fauxlore.notify_state_accounts(sp.state_id, 'religion_astroism',
        prefix || 'казна', 'Казна изменилась на ' || case when delta > 0 then '+' else '' end || delta || ' G.');
    end if;

    -- 5. Смерть правителя вне обычной проверки возраста: 1%.
    if random() < 0.01 then
      update fauxlore.state_characters
        set alive = false, died_at_turn = p_turn
        where state_id = sp.state_id and is_current_ruler and alive;
      if found then
        events := events || jsonb_build_array(jsonb_build_object(
          'effect', 'ruler_death', 'state', sp.state_id));
        insert into fauxlore.religion_turn_events(
          religion_id, state_id, game_year, game_turn, effect, target_state_id, target_province_id, delta, detail)
        values (religion_id, sp.state_id, p_year, p_turn, 'ruler_death', sp.state_id, null, null,
          jsonb_build_object('backfill', p_backfill));
        perform fauxlore.notify_state_accounts(sp.state_id, 'religion_astroism',
          prefix || 'предзнаменование',
          'Правитель умер вне обычной проверки возраста. Престол переходит по действующим правилам.');
      end if;
    end if;

    -- 6. Развитие случайной провинции на карте: 1%, от -50 до +50.
    if random() < 0.01 then
      select id into rnd_province from fauxlore.provinces where kind = 'land' order by random() limit 1;
      if rnd_province is not null then
        delta := floor(random() * 101)::integer - 50;
        update fauxlore.provinces
          set development = greatest(0, coalesce(development, 0) + delta)
          where id = rnd_province;
        select pv.category_id into owner_state
        from fauxlore.province_values pv
        where pv.province_id = rnd_province and pv.layer = 'states';
        events := events || jsonb_build_array(jsonb_build_object(
          'effect', 'map_province', 'state', sp.state_id, 'province', rnd_province, 'delta', delta));
        insert into fauxlore.religion_turn_events(
          religion_id, state_id, game_year, game_turn, effect, target_state_id, target_province_id, delta, detail)
        values (religion_id, sp.state_id, p_year, p_turn, 'map_province', owner_state, rnd_province, delta,
          jsonb_build_object('backfill', p_backfill));
        if owner_state is not null then
          perform fauxlore.notify_state_accounts(owner_state, 'religion_astroism',
            prefix || 'дальнее знамение',
            'Провинция «' || (select name from fauxlore.provinces where id = rnd_province) ||
            '» изменила развитие на ' || case when delta > 0 then '+' else '' end || delta || ' ед.');
        end if;
      end if;
    end if;
  end loop;

  return jsonb_build_object('year', p_year, 'turn', p_turn, 'backfill', p_backfill, 'events', events);
end
$fn$;

revoke all on function fauxlore.apply_astroism_turn_effects(integer,integer,boolean) from public, anon, authenticated;

create or replace function fauxlore.astroism_turn_effects_trigger()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if (new.year, new.turn) is distinct from (old.year, old.turn) then
    perform fauxlore.apply_astroism_turn_effects(new.year, new.turn, false);
  end if;
  return new;
end
$fn$;

drop trigger if exists zzzzzzzzzz_astroism_after_turn on fauxlore.game_calendar;
create trigger zzzzzzzzzz_astroism_after_turn
after update on fauxlore.game_calendar
for each row execute function fauxlore.astroism_turn_effects_trigger();
