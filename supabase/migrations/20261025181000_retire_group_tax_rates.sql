-- Archive retired group rates; four estate rates are the only active tax rates.
create table if not exists fauxlore.retired_state_tax_rates (like fauxlore.state_tax_rates including defaults);
insert into fauxlore.retired_state_tax_rates select * from fauxlore.state_tax_rates;
delete from fauxlore.state_tax_rates;
update fauxlore.economy_parameters set config=config-'raceTaxRates'-'religionTaxRates';
drop function if exists fauxlore.effective_state_tax_rate(integer,text,integer,jsonb);
CREATE OR REPLACE FUNCTION fauxlore.economy_config_api(path text, method text, body jsonb, request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a fauxlore.accounts; old_config jsonb; next_config jsonb; prior fauxlore.operations; fp text; item jsonb; pair record; key_name text; result jsonb;
begin
  if path='economy/config' and method='GET' then return (select config from fauxlore.economy_parameters where singleton=true); end if;
  if path not in ('admin/economy/config','economy/config') then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  select config into old_config from fauxlore.economy_parameters where singleton=true for update;
  if path='admin/economy/config' and method='GET' then return old_config; end if;
  if path<>'admin/economy/config' or method<>'PATCH' or request_id is null or body-'config'<>'{}' or jsonb_typeof(body->'config') is distinct from 'object' then
    raise sqlstate '22023' using message='Некорректное изменение параметров экономики'; end if;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into prior from fauxlore.operations where account_id=a.id and fauxlore.operations.request_id=economy_config_api.request_id;
  if found then if prior.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return prior.result; end if;
  next_config:=body->'config';
  if jsonb_typeof(next_config->'stateEffects') is distinct from 'object' then raise sqlstate '22023' using message='Нужны коэффициенты состояния'; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(next_config->'stateEffects') k) is distinct from
    (select array_agg(k order by k) from jsonb_object_keys(old_config->'stateEffects') k) then raise sqlstate '22023' using message='Изменён состав коэффициентов состояния'; end if;
  for pair in select key,value from jsonb_each(next_config->'stateEffects') loop
    if jsonb_typeof(pair.value) is distinct from 'number' then raise sqlstate '22023' using message='Коэффициент состояния должен быть числом'; end if;
    if (pair.value#>>'{}')::numeric<0 or (pair.value#>>'{}')::numeric>100 or
      (pair.key in ('crimeTaxPenalty','crimePopulationPenalty','corruptionTaxPenalty','corruptionLoyaltyCap','urbanizationThreshold','urbanizationPenaltyCap') and (pair.value#>>'{}')::numeric>1) or
      (pair.key='corruptionLoyaltyDivisor' and (pair.value#>>'{}')::numeric<.001) then raise sqlstate '22023' using message='Коэффициент состояния вне допустимого диапазона'; end if;
  end loop;

  if (select array_agg(k order by k) from jsonb_object_keys(next_config) k)<>
     (select array_agg(k order by k) from jsonb_object_keys(old_config) k) or next_config->'occupationMultiplier'<>'0.5'::jsonb then
    raise sqlstate '22023' using message='Набор параметров или коэффициент оккупации изменён'; end if;
  foreach key_name in array array['estateTaxRates','tradeStatusModifiers','raceGrowthModifiers','recruitGrowthModifiers','recruitLimitModifiers','estateRecruitModifiers','provinceValueWeights','estateTaxGreed'] loop
    if (select array_agg(k order by k) from jsonb_object_keys(next_config->key_name) k)<>
       (select array_agg(k order by k) from jsonb_object_keys(old_config->key_name) k) then raise sqlstate '22023' using message='Изменён состав справочника коэффициентов'; end if;
    for pair in select key,value from jsonb_each(next_config->key_name) loop
      if jsonb_typeof(pair.value)<>'number' or (pair.value#>>'{}')::numeric<0 or
        (pair.value#>>'{}')::numeric>(case when key_name='estateTaxGreed' then 1 else 10000 end) then
        raise sqlstate '22023' using message='Коэффициент должен быть числом в допустимом диапазоне'; end if;
    end loop;
  end loop;
  if jsonb_typeof(next_config->'taxLoyaltySensitivity')<>'number' or (next_config->>'taxLoyaltySensitivity')::numeric<0 or (next_config->>'taxLoyaltySensitivity')::numeric>5 then
    raise sqlstate '22023' using message='Чувствительность лояльности должна быть от 0 до 5'; end if;
  if (select array_agg(k order by k) from jsonb_object_keys(next_config->'provinceModifiers') k)<>
     (select array_agg(k order by k) from jsonb_object_keys(old_config->'provinceModifiers') k) then raise sqlstate '22023' using message='Изменён состав типов провинций'; end if;
  for pair in select key,value from jsonb_each(next_config->'provinceModifiers') loop
    if (select array_agg(k order by k) from jsonb_object_keys(pair.value) k)<>
       (select array_agg(k order by k) from jsonb_object_keys(old_config->'provinceModifiers'->pair.key) k) then raise sqlstate '22023' using message='Изменён состав модификатора типа'; end if;
    for key_name in select k from jsonb_object_keys(pair.value) k loop
      if jsonb_typeof(pair.value->key_name)<>'number' or (pair.value->>key_name)::numeric<0 or (pair.value->>key_name)::numeric>10000 then raise sqlstate '22023' using message='Модификатор должен быть числом от 0 до 10000'; end if;
    end loop;
  end loop;
  if jsonb_typeof(next_config->'resources')<>'array' or jsonb_array_length(next_config->'resources')<>jsonb_array_length(old_config->'resources') then raise sqlstate '22023' using message='Изменён состав ресурсов'; end if;
  for item in select value from jsonb_array_elements(next_config->'resources') loop
    if not exists(select 1 from jsonb_array_elements(old_config->'resources') old where old->>'name'=item->>'name' and old->'category'=item->'category' and old->'showInProduction'=item->'showInProduction') then raise sqlstate '22023' using message='Изменены сведения о ресурсе'; end if;
    foreach key_name in array array['value','production','consumption'] loop
      if jsonb_typeof(item->key_name)<>'number' or (item->>key_name)::numeric<0 or (item->>key_name)::numeric>1000000 then raise sqlstate '22023' using message='Параметр ресурса должен быть числом от 0 до 1000000'; end if;
    end loop;
  end loop;
  if jsonb_typeof(next_config->'tradeMarket')<>'object' or
    (select array_agg(k order by k) from jsonb_object_keys(next_config->'tradeMarket') k)<>
      (select array_agg(k order by k) from jsonb_object_keys(old_config->'tradeMarket') k) or
    jsonb_typeof(next_config#>'{tradeMarket,priceElasticity}') is distinct from 'number' or (next_config#>>'{tradeMarket,priceElasticity}')::numeric<.05 or (next_config#>>'{tradeMarket,priceElasticity}')::numeric>2 or
    jsonb_typeof(next_config#>'{tradeMarket,minPriceMultiplier}') is distinct from 'number' or (next_config#>>'{tradeMarket,minPriceMultiplier}')::numeric<.05 or (next_config#>>'{tradeMarket,minPriceMultiplier}')::numeric>=1 or
    jsonb_typeof(next_config#>'{tradeMarket,maxPriceMultiplier}') is distinct from 'number' or (next_config#>>'{tradeMarket,maxPriceMultiplier}')::numeric<=1 or (next_config#>>'{tradeMarket,maxPriceMultiplier}')::numeric>10 then
    raise sqlstate '22023' using message='Параметры рынка должны задавать эластичность 0,05–2, минимум 0,05–<1 и максимум >1–10';
  end if;
  insert into fauxlore.economy_parameter_history(account_id,before_config,after_config) values(a.id,old_config,next_config);
  update fauxlore.economy_parameters set config=next_config,updated_at=now() where singleton=true;
  result:=jsonb_build_object('config',next_config);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fp,result);
  return result;
end $function$
;
CREATE OR REPLACE FUNCTION fauxlore.state_tax_rates_api(path text, method text, body jsonb, request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a fauxlore.accounts; state_key integer; state_name text; calendar_row fauxlore.game_calendar; cfg jsonb;
  layer_key text; category_key integer; rate_value numeric; category_name text; prior fauxlore.operations;
  fp text; result jsonb; existing fauxlore.state_tax_rates; is_admin boolean;
begin
  a:=fauxlore.current_account(); is_admin:=a.role='admin';
  if path='admin/economy/treasuries' and method='GET' then
    if not is_admin then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id',s.state_id,'name',c.name,'treasury',s.treasury,'prestige',s.prestige,
      'debt',coalesce(d.balance,0),'players',coalesce((select jsonb_agg(ac.nickname order by ac.nickname) from fauxlore.account_states ast join fauxlore.accounts ac on ac.id=ast.account_id where ast.layer='states' and ast.state_id=s.state_id and ac.role<>'admin'),'[]'::jsonb),
      'buckets',coalesce((select jsonb_object_agg(t.estate,t.balance order by t.estate) from fauxlore.state_treasuries t where t.state_id=s.state_id),'{}'::jsonb)) order by c.name)
      from fauxlore.state_profiles s join fauxlore.map_categories c on c.layer='states' and c.id=s.state_id
      left join fauxlore.state_treasury_debts d on d.state_id=s.state_id),'[]'::jsonb);
  end if;
  if path !~ '^(my|admin)/states/[0-9]+/tax-rates$' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if (path like 'admin/%') is distinct from is_admin then raise sqlstate '42501' using message='Недостаточно прав'; end if;
  state_key:=substring(path from '[0-9]+')::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_key) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if not is_admin and not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_key) then
    raise sqlstate '42501' using message='Это государство не закреплено за вашим аккаунтом'; end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true;
  select config into cfg from fauxlore.economy_parameters where singleton=true;
  select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=state_key;
  if method='GET' then
    return jsonb_build_object('state_id',state_key,'state_name',state_name,'year',calendar_row.year,'turn',calendar_row.turn,
      'prestige',(select prestige from fauxlore.state_profiles where state_id=state_key),
      'treasury',(select treasury from fauxlore.state_profiles where state_id=state_key),
      'debt',coalesce((select balance from fauxlore.state_treasury_debts where state_id=state_key),0),
      'buckets',coalesce((select jsonb_object_agg(estate,balance) from fauxlore.state_treasuries where state_id=state_key),'{}'::jsonb),
      'army_upkeep_forecast',(select coalesce(sum(u.quantity*t.upkeep_per_unit),0)
        from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id where u.state_id=state_key),
      'groups','[]'::jsonb);
  end if;
  raise sqlstate 'P0002' using message='Налоговые ставки рас и религий отменены';
end $function$;
