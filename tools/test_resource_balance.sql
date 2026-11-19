-- Проверка механики профицита и дефицита ресурсов.
-- Запуск: psql -d <db> -v ON_ERROR_STOP=1 -f tools/test_resource_balance.sql
-- Скрипт работает в транзакции и завершается откатом, данные не меняются.
begin;

do $check$
declare
  effects integer;
  journal_turn record;
  example_state integer;
  statuses integer;
  bad_status integer;
  base_count integer;
  full_count integer;
  resource_count integer;
  scoped_state integer;
  grain_province integer;
  scoped_bonus numeric;
  other_bonus numeric;
  clean_state integer;
  clean_count integer;
  limit_base integer;
  limit_modifier numeric;
  limit_effective integer;
begin
  select count(*) into effects from fauxlore.resource_balance_effects;
  if effects<60 then raise exception 'Слишком мало эффектов ресурсов: %',effects; end if;

  select year,turn into journal_turn from fauxlore.trade_state_resource_turns
    order by year desc,turn desc limit 1;
  if journal_turn is null then raise exception 'Нет журнала торговых ресурсов'; end if;

  select state_id into example_state from fauxlore.trade_state_resource_turns
    where year=journal_turn.year and turn=journal_turn.turn
    group by state_id having count(*)>3 order by state_id limit 1;

  select count(*) into statuses from fauxlore.state_resource_balances(example_state);
  if statuses=0 then raise exception 'Нет статусов ресурсов для государства %',example_state; end if;

  select count(*) into bad_status from fauxlore.state_resource_balances(example_state)
    where (status='deficit' and amount>-100) or (status='surplus' and amount<500)
      or (status='normal' and (amount<=-100 or amount>=500));
  if bad_status>0 then raise exception 'Порог статуса нарушен у % строк',bad_status; end if;

  select count(*) into full_count from jsonb_array_elements(fauxlore.state_permanent_modifiers(example_state));
  select count(*) into base_count from jsonb_array_elements(fauxlore.state_permanent_modifiers_base(example_state));
  if full_count<base_count then raise exception 'Потеряны базовые модификаторы: % < %',full_count,base_count; end if;

  select count(*) into resource_count from jsonb_array_elements(fauxlore.state_permanent_modifiers(example_state))
    where value->>'source_kind'='resource';
  if resource_count>0 and full_count<>base_count+resource_count then
    raise exception 'Неверная сумма модификаторов: % <> % + %',full_count,base_count,resource_count;
  end if;

  -- Ресурсный профицит Селитры даёт +20% производства в провинциях с зерном.
  select p.id into grain_province from fauxlore.provinces p
    join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
    join fauxlore.province_values r on r.province_id=p.id and r.layer='resources'
    join fauxlore.map_categories c on c.layer='resources' and c.id=r.category_id
    where c.name='Зерно' and v.category_id=example_state limit 1;
  if grain_province is not null then
    insert into fauxlore.trade_state_resource_turns
      (year,turn,state_id,resource_name,production,consumption,contract_import,contract_export,
       zone_import,zone_export,base_price,dynamic_price,internal_quantity,turnover,duty_income)
    values(journal_turn.year+1,1,example_state,'Селитра',900,0,0,0,0,0,7,7,0,0,0)
    on conflict do nothing;
    scoped_bonus:=fauxlore.state_permanent_modifier_total(example_state,array['production'],grain_province,'Зерно');
    other_bonus:=fauxlore.state_permanent_modifier_total(example_state,array['production'],grain_province,'Лес');
    if scoped_bonus<other_bonus+.19 then
      raise exception 'Бонус селитры не применён к зерну: % против %',scoped_bonus,other_bonus;
    end if;
    delete from fauxlore.trade_state_resource_turns where year=journal_turn.year+1 and state_id=example_state;
  end if;

  -- Государство без журнала не получает ресурсных модификаторов.
  select sp.state_id into clean_state from fauxlore.state_profiles sp
    where not exists(select 1 from fauxlore.trade_state_resource_turns r where r.state_id=sp.state_id) limit 1;
  if clean_state is not null then
    select count(*) into clean_count from jsonb_array_elements(fauxlore.state_permanent_modifiers(clean_state))
      where value->>'source_kind'='resource';
    if clean_count>0 then raise exception 'Ресурсные модификаторы без журнала у %',clean_state; end if;
  end if;

  if position('construction_cost' in pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure))=0 then
    raise exception 'Стоимость строительства не учитывает модификатор'; end if;
  if position('construction_cost' in pg_get_functiondef('fauxlore.military_start_port_construction(integer,jsonb)'::regprocedure))=0 then
    raise exception 'Стоимость порта не учитывает модификатор'; end if;
  if position('colonization_cost' in pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure))=0 then
    raise exception 'Стоимость колонизации не учитывает модификатор'; end if;
  if position('key_estate_loyalty' in pg_get_functiondef('fauxlore.effective_estate_loyalties(integer)'::regprocedure))=0 then
    raise exception 'Лояльность ключевых сословий не учитывает модификатор'; end if;

  -- Действующий лимит развития = база + модификаторы, и оба значения отдаются API.
  select (fauxlore.state_indicators(example_state)->>'development_limit_base')::integer,
    (fauxlore.state_indicators(example_state)->>'development_limit_modifier')::numeric,
    (fauxlore.state_indicators(example_state)->>'development_limit')::integer
    into limit_base,limit_modifier,limit_effective;
  if limit_base is null or limit_modifier is null or limit_effective is null then
    raise exception 'API не отдаёт базовый и действующий лимит развития'; end if;
  if limit_effective<>greatest(0,(limit_base+limit_modifier)::integer) then
    raise exception 'Лимит развития не равен базе с модификаторами: % <> % + %',limit_effective,limit_base,limit_modifier; end if;
  if limit_modifier<>fauxlore.state_permanent_modifier_total(example_state,array['development_limit_flat'],null,null) then
    raise exception 'Модификатор лимита развития не совпадает с суммой модификаторов'; end if;

  raise notice 'Resource balance modifiers: % effects, state %, % statuses, % resource modifiers',
    effects,example_state,statuses,resource_count;
end $check$;

rollback;
