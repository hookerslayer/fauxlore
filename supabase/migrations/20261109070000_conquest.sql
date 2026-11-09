-- Завоевание нейтральных провинций как второй способ присоединения земель.
--
-- Механика:
--   * армия (регулярная или наёмная, не ополчение) стоит в нейтральной провинции;
--   * минимум 300 солдат в выбранном формировании;
--   * бросок 0–100: +5 за каждые 100 солдат, −1 за каждые 10 развития,
--     −2 за каждые 500 населения, штрафы последствий и неудачной колонизации;
--   * 2 попытки за ход, одну провинцию нельзя завоевать дважды за ход;
--   * при успехе провинция сразу переходит государству, развитие ×0,5,
--     население 10% + 500 переселенцев из своих провинций;
--   * соседние провинции получают −15 к колонизации и −10 к завоеванию навсегда.
--
-- Откат: drop function fauxlore.conquest_api(text,integer,jsonb);
--        drop function fauxlore.conquest_dice_modifiers(integer,integer,integer,integer,integer);
--        drop function fauxlore.conquest_outcome(integer);
--        drop table fauxlore.conquest_attempts;
--        drop table fauxlore.conquest_aftermath;
--        восстановить colonization_api и colonization_dice_modifiers из бэкапа.

do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to install conquest mechanics outside production candidate';
  end if;
end
$guard$;

create table if not exists fauxlore.conquest_attempts(
  id bigserial primary key,
  state_id integer not null,
  province_id integer not null,
  year integer not null,
  turn integer not null,
  formation_id bigint,
  soldiers integer not null default 0,
  roll integer,
  final_result integer,
  success boolean,
  loss_percent integer,
  created_at timestamp with time zone not null default now()
);
revoke all on fauxlore.conquest_attempts from public, anon, authenticated;
grant select on fauxlore.conquest_attempts to service_role;
grant usage on sequence fauxlore.conquest_attempts_id_seq to service_role;
create index if not exists conquest_attempts_state_turn on fauxlore.conquest_attempts(state_id, year, turn);
create index if not exists conquest_attempts_province_turn on fauxlore.conquest_attempts(province_id, year, turn);

create table if not exists fauxlore.conquest_aftermath(
  province_id integer primary key,
  source_province_id integer not null,
  colonization_penalty integer not null default -15,
  conquest_penalty integer not null default -10,
  created_at timestamp with time zone not null default now()
);
revoke all on fauxlore.conquest_aftermath from public, anon, authenticated;
grant select on fauxlore.conquest_aftermath to service_role;

create or replace function fauxlore.conquest_outcome(p_value integer)
returns table(success boolean, loss_percent integer)
language sql
immutable
as $fn$
  select case when v between 31 and 100 then true else false end,
         case when v between 0 and 10 then 100
              when v between 11 and 20 then 50
              when v between 21 and 30 then 15
              when v between 31 and 40 then 60
              when v between 41 and 50 then 50
              when v between 51 and 60 then 40
              when v between 61 and 70 then 30
              when v between 71 and 80 then 20
              when v between 81 and 90 then 10
              when v between 91 and 100 then 5
              else 100 end
  from (select greatest(0, least(100, p_value)) v) s;
$fn$;

create or replace function fauxlore.conquest_dice_modifiers(
  p_state integer, p_province integer, p_soldiers integer, p_year integer, p_turn integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $fn$
declare
  result jsonb := '[]'::jsonb;
  dev integer;
  pop bigint;
  penalty integer;
begin
  select coalesce(development, 0), coalesce(population, 0) into dev, pop
  from fauxlore.provinces where id = p_province;

  if p_soldiers >= 100 then
    result := result || jsonb_build_array(jsonb_build_object(
      'source', 'Армия (' || (p_soldiers / 100) * 100 || ' солдат)', 'value', (p_soldiers / 100) * 5));
  end if;
  if dev >= 10 then
    result := result || jsonb_build_array(jsonb_build_object('source', 'Развитие провинции', 'value', -(dev / 10)));
  end if;
  if pop >= 500 then
    result := result || jsonb_build_array(jsonb_build_object('source', 'Население провинции', 'value', -(pop / 500) * 2));
  end if;
  select conquest_penalty into penalty from fauxlore.conquest_aftermath where province_id = p_province;
  if penalty is not null and penalty <> 0 then
    result := result || jsonb_build_array(jsonb_build_object('source', 'Последствия завоевания', 'value', penalty));
  end if;
  if exists(select 1 from fauxlore.colonization_attempts a
            where a.province_id = p_province and a.year = p_year and a.turn = p_turn and not a.success) then
    result := result || jsonb_build_array(jsonb_build_object('source', 'Неудачная колонизация', 'value', -5));
  end if;
  return result;
end
$fn$;

create or replace function fauxlore.conquest_api(action text, target_state integer, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  account_row fauxlore.accounts;
  state_key integer;
  year_value integer;
  turn_value integer;
  target_key integer;
  formation_key bigint;
  p fauxlore.provinces;
  f fauxlore.military_formations;
  soldiers integer;
  dev integer;
  pop bigint;
  modifiers jsonb := '[]'::jsonb;
  dice_total integer := 0;
  dice_detail text := '';
  roll_value integer;
  final_value integer;
  success_value boolean;
  loss_pct integer;
  new_dev integer;
  new_pop bigint;
  total_dev numeric := 0;
  accumulated numeric := 0;
  previous integer := 0;
  take integer;
  rec record;
  lost integer;
  remaining integer;
  attempts_used integer;
  result jsonb;
begin
  select * into account_row from fauxlore.current_account();
  if account_row.id is null then raise sqlstate '42501' using message = 'Требуется вход'; end if;
  state_key := coalesce(target_state, (select a.state_id from fauxlore.account_states a
    where a.account_id = account_row.id and a.layer = 'states' order by a.state_id limit 1));
  if state_key is null then raise sqlstate '22023' using message = 'Государство не выбрано'; end if;
  if coalesce(account_row.role, '') <> 'admin' and not exists(
      select 1 from fauxlore.account_states a
      where a.account_id = account_row.id and a.layer = 'states' and a.state_id = state_key) then
    raise sqlstate '42501' using message = 'Нет доступа к государству';
  end if;
  select year, turn into year_value, turn_value from fauxlore.game_calendar where singleton = true;
  if action not in ('snapshot', 'preview', 'attempt') then
    raise sqlstate '22023' using message = 'Неизвестное действие завоевания';
  end if;

  if action = 'snapshot' then
    select count(*) into attempts_used from fauxlore.conquest_attempts
    where state_id = state_key and year = year_value and turn = turn_value;
    return jsonb_build_object(
      'attempts_used', attempts_used,
      'attempts_limit', 2,
      'attempts_left', greatest(0, 2 - attempts_used),
      'armies', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', f2.id, 'name', f2.name, 'province_id', f2.province_id,
          'province_name', pr.name, 'kind', f2.kind,
          'soldiers', coalesce((select sum(fu.quantity) from fauxlore.military_formation_units fu
                                where fu.formation_id = f2.id), 0))
          order by f2.id)
        from fauxlore.military_formations f2
        join fauxlore.provinces pr on pr.id = f2.province_id and pr.kind = 'land'
        where f2.state_id = state_key and f2.active and f2.domain = 'land'
          and f2.kind <> 'militia'
          and not exists(select 1 from fauxlore.province_values v
                         where v.province_id = f2.province_id and v.layer = 'states')
      ), '[]'::jsonb));
  end if;

  if jsonb_typeof(payload) is distinct from 'object' then
    raise sqlstate '22023' using message = 'Некорректный запрос';
  end if;
  target_key := (payload->>'province_id')::integer;
  formation_key := (payload->>'formation_id')::bigint;
  select * into p from fauxlore.provinces where id = target_key and kind = 'land' for update;
  if not found then raise sqlstate '22023' using message = 'Выберите сухопутную провинцию'; end if;
  if exists(select 1 from fauxlore.province_values v where v.province_id = target_key and v.layer = 'states') then
    raise sqlstate '22023' using message = 'Завоёвывать можно только нейтральную провинцию';
  end if;
  if exists(select 1 from fauxlore.colonization_missions m where m.province_id = target_key and m.status = 'active') then
    raise sqlstate '22023' using message = 'Эта провинция уже колонизируется';
  end if;
  if exists(select 1 from fauxlore.conquest_attempts a
            where a.province_id = target_key and a.year = year_value and a.turn = turn_value) then
    raise sqlstate '22023' using message = 'Эту провинцию уже пытались завоевать в этом ходу';
  end if;
  select count(*) into attempts_used from fauxlore.conquest_attempts
  where state_id = state_key and year = year_value and turn = turn_value;
  if attempts_used >= 2 then
    raise sqlstate '22023' using message = 'За ход можно провести не более двух завоеваний';
  end if;

  select * into f from fauxlore.military_formations
  where id = formation_key and state_id = state_key and active and domain = 'land'
    and kind <> 'militia' and province_id = target_key for update;
  if not found then
    raise sqlstate '22023' using message = 'Выберите регулярную или наёмную армию в этой провинции';
  end if;
  select coalesce(sum(quantity), 0) into soldiers from fauxlore.military_formation_units where formation_id = formation_key;
  if soldiers < 300 then
    raise sqlstate '22023' using message = 'Для завоевания нужно минимум 300 солдат в формировании';
  end if;

  select coalesce(development, 0), coalesce(population, 0) into dev, pop from fauxlore.provinces where id = target_key;
  modifiers := fauxlore.conquest_dice_modifiers(state_key, target_key, soldiers, year_value, turn_value);
  select coalesce(sum((value->>'value')::integer), 0),
         coalesce(string_agg(format('%s %s (%s)',
           case when (value->>'value')::integer > 0 then '+' else '−' end,
           abs((value->>'value')::integer), value->>'source'), ' ' order by ord), '')
    into dice_total, dice_detail
  from jsonb_array_elements(modifiers) with ordinality as t(value, ord);

  if action = 'preview' then
    return jsonb_build_object(
      'province_id', target_key, 'province_name', p.name,
      'development', dev, 'population', pop, 'soldiers', soldiers,
      'modifiers', modifiers, 'modifiers_total', dice_total,
      'attempts_left', greatest(0, 2 - attempts_used),
      'min_result', greatest(0, least(100, dice_total)),
      'max_result', greatest(0, least(100, 100 + dice_total)));
  end if;

  roll_value := floor(random() * 101)::integer;
  final_value := greatest(0, least(100, roll_value + dice_total));
  select o.success, o.loss_percent into success_value, loss_pct from fauxlore.conquest_outcome(final_value) o;

  for rec in select unit_id, quantity from fauxlore.military_formation_units where formation_id = formation_key loop
    if loss_pct >= 100 then
      delete from fauxlore.military_formation_units where formation_id = formation_key and unit_id = rec.unit_id;
    else
      lost := floor(rec.quantity * loss_pct / 100.0)::integer;
      remaining := rec.quantity - lost;
      if remaining <= 0 then
        delete from fauxlore.military_formation_units where formation_id = formation_key and unit_id = rec.unit_id;
      else
        update fauxlore.military_formation_units set quantity = remaining
        where formation_id = formation_key and unit_id = rec.unit_id;
      end if;
    end if;
  end loop;

  if success_value then
    new_dev := floor(dev * 0.5)::integer;
    new_pop := floor(pop * 0.1)::bigint + 500;
    insert into fauxlore.province_values(province_id, layer, category_id)
      values(target_key, 'states', state_key)
      on conflict (province_id, layer) do update set category_id = excluded.category_id;
    update fauxlore.provinces p2 set
      development = new_dev,
      population = new_pop,
      control = 100,
      province_type = case
        when exists(select 1 from fauxlore.map_markers mk where mk.province_id = p2.id and mk.type = 'capital') then 'Столичная'
        when exists(select 1 from fauxlore.map_markers mk where mk.province_id = p2.id and mk.type = 'city') then 'Городская'
        else 'Регион' end
    where p2.id = target_key;

    select coalesce(sum(p3.development), 0) into total_dev
    from fauxlore.provinces p3
    join fauxlore.province_values v on v.province_id = p3.id and v.layer = 'states' and v.category_id = state_key
    where p3.kind = 'land' and p3.id <> target_key;
    if total_dev > 0 then
      for rec in
        select p3.id, p3.development from fauxlore.provinces p3
        join fauxlore.province_values v on v.province_id = p3.id and v.layer = 'states' and v.category_id = state_key
        where p3.kind = 'land' and p3.id <> target_key
        order by p3.development desc, p3.id
      loop
        accumulated := accumulated + 500.0 * rec.development / total_dev;
        take := floor(accumulated)::integer - previous;
        previous := floor(accumulated)::integer;
        if take > 0 then
          update fauxlore.provinces set population = greatest(0, coalesce(population, 0) - take) where id = rec.id;
        end if;
      end loop;
    end if;

    insert into fauxlore.conquest_aftermath(province_id, source_province_id)
    select (n.value)::integer, target_key
    from fauxlore.map_adjacency a
    join lateral jsonb_array_elements_text(a.neighbors->(target_key::text)) n(value) on true
    join fauxlore.provinces np on np.id = (n.value)::integer and np.kind = 'land'
    where a.singleton and (n.value)::integer <> target_key
    on conflict (province_id) do update
      set source_province_id = excluded.source_province_id,
          colonization_penalty = -15, conquest_penalty = -10, created_at = now();

    insert into fauxlore.notifications(account_id, kind, title, message)
    select recipients.account_id, 'conquest', 'Провинция завоёвана',
      format('Провинция «%s» перешла государству. Итог %s (%s %s = %s), потери: %s%% армии. Соседние провинции получили −15 к колонизации и −10 к завоеванию.',
        p.name, final_value, roll_value, dice_detail, final_value, loss_pct)
    from (select distinct ast.account_id from fauxlore.account_states ast
          where ast.layer = 'states' and ast.state_id = state_key
          union select ac.id from fauxlore.accounts ac where ac.role = 'admin') recipients;
  else
    insert into fauxlore.notifications(account_id, kind, title, message)
    select recipients.account_id, 'conquest_failed', 'Завоевание не удалось',
      format('Провинция «%s» не покорена. Итог %s (%s %s = %s), потери: %s%% армии.',
        p.name, final_value, roll_value, dice_detail, final_value, loss_pct)
    from (select distinct ast.account_id from fauxlore.account_states ast
          where ast.layer = 'states' and ast.state_id = state_key
          union select ac.id from fauxlore.accounts ac where ac.role = 'admin') recipients;
  end if;

  insert into fauxlore.conquest_attempts(
    state_id, province_id, year, turn, formation_id, soldiers, roll, final_result, success, loss_percent)
  values (state_key, target_key, year_value, turn_value, formation_key, soldiers, roll_value, final_value, success_value, loss_pct);

  result := jsonb_build_object(
    'success', success_value, 'roll', roll_value, 'result', final_value,
    'loss_percent', loss_pct, 'soldiers', soldiers,
    'soldiers_lost', floor(soldiers * loss_pct / 100.0)::integer,
    'province_id', target_key, 'province_name', p.name,
    'modifiers', modifiers, 'modifiers_total', dice_total,
    'development', case when success_value then new_dev else dev end,
    'population', case when success_value then new_pop else pop end,
    'attempts_left', greatest(0, 2 - attempts_used - 1));
  return result;
end
$fn$;

grant execute on function fauxlore.conquest_api(text, integer, jsonb) to authenticated;
grant execute on function fauxlore.conquest_dice_modifiers(integer, integer, integer, integer, integer) to authenticated;
grant execute on function fauxlore.conquest_outcome(integer) to authenticated;

-- Колонизацию нельзя пытаться провести в провинции, которую в этом ходу завоёвывали.
do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure) into definition;
  marker := '  sea_value:=coalesce((payload->>''sea'')::boolean,false);';
  if position(marker in definition) = 0 then raise exception 'Could not locate colonization API marker'; end if;
  replacement := marker || E'\n  if exists(select 1 from fauxlore.conquest_attempts a where a.province_id=target_key and a.year=year_value and a.turn=turn_value) then raise sqlstate ''22023'' using message=''Эту провинцию уже пытались завоевать в этом ходу''; end if;';
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;

-- Штраф последствий завоевания применяется и к колонизации соседних провинций.
do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.colonization_dice_modifiers(integer,integer,integer,integer,integer)'::regprocedure) into definition;
  marker := '  return result;';
  if position(marker in definition) = 0 then raise exception 'Could not locate dice modifiers marker'; end if;
  replacement := E'  for a in select colonization_penalty from fauxlore.conquest_aftermath where province_id=pid loop\n    result:=result||jsonb_build_array(jsonb_build_object(''source'',''Последствия завоевания'',''value'',a.colonization_penalty));\n  end loop;\n' || marker;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
