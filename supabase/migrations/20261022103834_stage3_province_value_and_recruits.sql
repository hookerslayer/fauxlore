-- Stage 3: independent recruitment modifiers, weighted province value, and
-- server-side value calculations used by political support.
update fauxlore.economy_parameters
set config=config||jsonb_build_object(
  'recruitGrowthModifiers',coalesce(config->'recruitGrowthModifiers','{"Столичная":1.5,"Городская":1,"Регион":0.5,"Территориальная":0}'::jsonb),
  'recruitLimitModifiers',coalesce(config->'recruitLimitModifiers','{"Столичная":1.5,"Городская":1,"Регион":0.5,"Территориальная":0}'::jsonb),
  'estateRecruitModifiers',coalesce(config->'estateRecruitModifiers','{"Корона":1.5,"Знать":1.2,"Духовенство":0.3,"Горожане":0.5,"Крестьяне":0.1}'::jsonb),
  'provinceValueWeights',coalesce(config->'provinceValueWeights','{"gold":0.001,"trade":0.005,"production":0.005,"recruits":0.002,"population":0.0005}'::jsonb),
  'taxLoyaltySensitivity',coalesce(config->'taxLoyaltySensitivity','0.5'::jsonb)
)
where singleton=true;

create or replace function fauxlore.province_value_for_state(target_province integer,target_state integer)
returns numeric language plpgsql stable security definer set search_path='' as $$
declare p fauxlore.provinces; cfg jsonb; state_name text; owner_state integer;
  race_name text; religion_name text; resource_name text; tax_mod numeric; prod_mod numeric;
  trade_mod numeric; trade_base numeric; trade_status_mod numeric; race_rate numeric; religion_rate numeric;
  resource_value numeric:=0; resource_prod numeric:=0; crime_rate numeric:=.2;
  share numeric:=0; control_value numeric; population numeric; tax_value numeric; production_value numeric;
  trade_value numeric; recruit_limit numeric; weights jsonb;
begin
  select * into p from fauxlore.provinces where id=target_province and kind='land';
  if not found then return null; end if;
  select config into cfg from fauxlore.economy_parameters where singleton=true;
  select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=target_state;
  select category_id into owner_state from fauxlore.province_values where province_id=p.id and layer='states';
  select c.name into race_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='races';
  select c.name into religion_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='religions';
  select c.name into resource_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='resources';
  if race_name is null or religion_name is null or state_name is null then return null; end if;
  if p.occupation is not null and (owner_state is null or lower(p.occupation)<>lower((select name from fauxlore.map_categories where layer='states' and id=owner_state))) then
    if lower(p.occupation)=lower(state_name) then share:=coalesce((cfg->>'occupationMultiplier')::numeric,.5); end if;
  elsif owner_state=target_state then share:=1;
  end if;
  if share=0 then return 0; end if;
  tax_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'tax'],'')::numeric;
  prod_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'production'],'')::numeric;
  trade_mod:=nullif(cfg#>>array['provinceModifiers',p.province_type,'trade'],'')::numeric;
  trade_base:=nullif(cfg#>>array['provinceModifiers',p.province_type,'tradeBase'],'')::numeric;
  race_rate:=nullif(cfg#>>array['raceTaxRates',race_name],'')::numeric;
  religion_rate:=nullif(cfg#>>array['religionTaxRates',religion_name],'')::numeric;
  trade_status_mod:=nullif(cfg#>>array['tradeStatusModifiers',coalesce(p.trade_status,'Отсутствует')],'')::numeric;
  if tax_mod is null or prod_mod is null or trade_mod is null or trade_base is null or race_rate is null or religion_rate is null or trade_status_mod is null then return null; end if;
  select coalesce((r->>'value')::numeric,0),coalesce((r->>'production')::numeric,0) into resource_value,resource_prod
    from jsonb_array_elements(cfg->'resources') r where r->>'name'=resource_name limit 1;
  select coalesce(crime,.2) into crime_rate from fauxlore.state_profiles where state_id=target_state;
  crime_rate:=coalesce(crime_rate,.2); population:=greatest(0,p.population)::numeric;
  control_value:=coalesce(p.control,100)::numeric/100;
  tax_value:=round(population/10*(race_rate+religion_rate)*tax_mod*control_value*share,2);
  production_value:=round(population*resource_prod*prod_mod*control_value*(1-crime_rate)*share,0);
  trade_value:=round(trade_base*trade_mod*trade_status_mod*share,2);
  recruit_limit:=round(population/100
    *coalesce((cfg#>>array['recruitLimitModifiers',p.province_type])::numeric,0)
    *case when p.belonging='Отсутствует' then 0 else coalesce((cfg#>>array['estateRecruitModifiers',p.belonging])::numeric,0) end
    *control_value*share,0);
  weights:=cfg->'provinceValueWeights';
  return round(((tax_value+production_value*resource_value)*coalesce((weights->>'gold')::numeric,0))
    +(trade_value*coalesce((weights->>'trade')::numeric,0))
    +(production_value*resource_value*coalesce((weights->>'production')::numeric,0))
    +(recruit_limit*coalesce((weights->>'recruits')::numeric,0))
    +(population*coalesce((weights->>'population')::numeric,0)*share),0);
end $$;
revoke all on function fauxlore.province_value_for_state(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.economy_config_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  if (select array_agg(k order by k) from jsonb_object_keys(next_config) k)<>
     (select array_agg(k order by k) from jsonb_object_keys(old_config) k) or next_config->'occupationMultiplier'<>'0.5'::jsonb then
    raise sqlstate '22023' using message='Набор параметров или коэффициент оккупации изменён'; end if;
  foreach key_name in array array['raceTaxRates','religionTaxRates','tradeStatusModifiers','raceGrowthModifiers','recruitGrowthModifiers','recruitLimitModifiers','estateRecruitModifiers','provinceValueWeights'] loop
    if (select array_agg(k order by k) from jsonb_object_keys(next_config->key_name) k)<>
       (select array_agg(k order by k) from jsonb_object_keys(old_config->key_name) k) then raise sqlstate '22023' using message='Изменён состав справочника коэффициентов'; end if;
    for pair in select key,value from jsonb_each(next_config->key_name) loop
      if jsonb_typeof(pair.value)<>'number' or (pair.value#>>'{}')::numeric<0 or (pair.value#>>'{}')::numeric>10000 then
        raise sqlstate '22023' using message='Коэффициент должен быть числом от 0 до 10000'; end if;
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
  insert into fauxlore.economy_parameter_history(account_id,before_config,after_config) values(a.id,old_config,next_config);
  update fauxlore.economy_parameters set config=next_config,updated_at=now() where singleton=true;
  result:=jsonb_build_object('config',next_config);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.economy_config_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.economy_config_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
