-- Проверка завоевания. Выполняется в транзакции и откатывается.
-- Запуск: psql -v ON_ERROR_STOP=1 -f test_conquest.sql
begin;

do $test$
declare
  fid bigint;
  result jsonb;
  expected_pop bigint;
  old_pop bigint;
  expected_race integer;
  expected_religion integer;
  actual_race integer;
  actual_religion integer;
  actual_pop bigint;
  before_pop bigint;
  after_pop bigint;
  expected_loss integer;
  actual_quantity integer;
  ok boolean;
  loss integer;
begin
  perform set_config('request.jwt.claim.sub', '93673aea-9523-47d1-a66a-4804e91d8182', true);

  select o.success, o.loss_percent into ok, loss from fauxlore.conquest_outcome(5) o;
  if ok or loss <> 100 then raise exception 'outcome 5 expected fail/100'; end if;
  select o.success, o.loss_percent into ok, loss from fauxlore.conquest_outcome(40) o;
  if not ok or loss <> 60 then raise exception 'outcome 40 expected success/60'; end if;
  select o.success, o.loss_percent into ok, loss from fauxlore.conquest_outcome(91) o;
  if not ok or loss <> 5 then raise exception 'outcome 91 expected success/5'; end if;

  select coalesce(sum(p.population), 0) into before_pop
  from fauxlore.provinces p
  join fauxlore.province_values v on v.province_id = p.id and v.layer = 'states' and v.category_id = 6
  where p.kind = 'land' and p.id <> 2597;

  insert into fauxlore.military_formations(state_id, name, domain, kind, province_id, active)
  values (6, 'Тестовая завоевательная армия', 'land', 'regular', 2597, true)
  returning id into fid;
  insert into fauxlore.military_formation_units(formation_id, unit_id, quantity) values (fid, 1, 300);
  select coalesce(population, 0) into old_pop from fauxlore.provinces where id = 2597;

  perform setseed(0.9);
  result := fauxlore.conquest_api('attempt', 6, jsonb_build_object('province_id', 2597, 'formation_id', fid));
  if not (result->>'success')::boolean then
    raise exception 'seeded conquest expected success, got %', result;
  end if;
  if (select category_id from fauxlore.province_values where province_id = 2597 and layer = 'states') <> 6 then
    raise exception 'province was not assigned to the state';
  end if;
  select official_race_id, official_religion_id into expected_race, expected_religion
  from fauxlore.state_profiles where state_id = 6;
  select category_id into actual_race from fauxlore.province_values where province_id = 2597 and layer = 'races';
  select category_id into actual_religion from fauxlore.province_values where province_id = 2597 and layer = 'religions';
  if expected_race is not null and actual_race is distinct from expected_race then
    raise exception 'race expected %, got %', expected_race, actual_race;
  end if;
  if expected_religion is not null and actual_religion is distinct from expected_religion then
    raise exception 'religion expected %, got %', expected_religion, actual_religion;
  end if;
  if (select development from fauxlore.provinces where id = 2597) <> 50 then
    raise exception 'development was not halved';
  end if;
  select floor(old_pop * 0.1)::bigint + 500 into expected_pop;
  select population into actual_pop from fauxlore.provinces where id = 2597;
  if actual_pop <> expected_pop then
    raise exception 'population expected %, got %', expected_pop, actual_pop;
  end if;

  expected_loss := (result->>'loss_percent')::integer;
  select coalesce(quantity, 0) into actual_quantity from fauxlore.military_formation_units where formation_id = fid;
  if actual_quantity <> greatest(0, 300 - floor(300 * expected_loss / 100.0)::integer) then
    raise exception 'losses expected %, got % units', expected_loss, actual_quantity;
  end if;

  if not exists(select 1 from fauxlore.conquest_aftermath where source_province_id = 2597) then
    raise exception 'neighbour penalties were not created';
  end if;

  select coalesce(sum(p.population), 0) into after_pop
  from fauxlore.provinces p
  join fauxlore.province_values v on v.province_id = p.id and v.layer = 'states' and v.category_id = 6
  where p.kind = 'land' and p.id <> 2597;
  if before_pop - after_pop <> 500 then
    raise exception 'settlers expected 500, got %', before_pop - after_pop;
  end if;

  begin
    perform fauxlore.conquest_api('attempt', 6, jsonb_build_object('province_id', 2597, 'formation_id', fid));
    raise exception 'second conquest of the same province in one turn was allowed';
  exception when sqlstate '22023' then null;
  end;
end
$test$;

rollback;
