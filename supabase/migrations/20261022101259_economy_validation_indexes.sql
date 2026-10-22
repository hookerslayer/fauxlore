-- Tighten structural/numeric validation and index economy change history.
create index if not exists economy_parameter_history_account_changed_idx on fauxlore.economy_parameter_history(account_id,changed_at desc);

create or replace function fauxlore.economy_config_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; old_config jsonb; next_config jsonb; prior fauxlore.operations; fp text; item jsonb; pair record; key_name text; result jsonb;
begin
  if path='economy/config' and method='GET' then
    return (select config from fauxlore.economy_parameters where singleton=true);
  end if;
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
  foreach key_name in array array['raceTaxRates','religionTaxRates','tradeStatusModifiers','raceGrowthModifiers'] loop
    if (select array_agg(k order by k) from jsonb_object_keys(next_config->key_name) k)<>
       (select array_agg(k order by k) from jsonb_object_keys(old_config->key_name) k) then raise sqlstate '22023' using message='Изменён состав справочника коэффициентов'; end if;
    for pair in select key,value from jsonb_each(next_config->key_name) loop
      if jsonb_typeof(pair.value) is distinct from 'number' or (pair.value#>>'{}')::numeric<0 or (pair.value#>>'{}')::numeric>10000 then
        raise sqlstate '22023' using message='Коэффициент должен быть числом от 0 до 10000'; end if;
    end loop;
  end loop;
  if (select array_agg(k order by k) from jsonb_object_keys(next_config->'provinceModifiers') k)<>
     (select array_agg(k order by k) from jsonb_object_keys(old_config->'provinceModifiers') k) then raise sqlstate '22023' using message='Изменён состав типов провинций'; end if;
  for pair in select key,value from jsonb_each(next_config->'provinceModifiers') loop
    if (select array_agg(k order by k) from jsonb_object_keys(pair.value) k)<>
       (select array_agg(k order by k) from jsonb_object_keys(old_config->'provinceModifiers'->pair.key) k) then raise sqlstate '22023' using message='Изменён состав модификатора типа'; end if;
    for key_name in select k from jsonb_object_keys(pair.value) k loop
      if jsonb_typeof(pair.value->key_name) is distinct from 'number' or (pair.value->>key_name)::numeric<0 or (pair.value->>key_name)::numeric>10000 then raise sqlstate '22023' using message='Модификатор должен быть числом от 0 до 10000'; end if;
    end loop;
  end loop;
  if jsonb_typeof(next_config->'resources')<>'array' or jsonb_array_length(next_config->'resources')<>jsonb_array_length(old_config->'resources') then raise sqlstate '22023' using message='Изменён состав ресурсов'; end if;
  if (select count(distinct x->>'name') from jsonb_array_elements(next_config->'resources') x)<>jsonb_array_length(next_config->'resources') then raise sqlstate '22023' using message='Ресурсы должны быть уникальны'; end if;
  for item in select value from jsonb_array_elements(next_config->'resources') loop
    if item-array['category','name','value','production','consumption','showInProduction']<>'{}' then raise sqlstate '22023' using message='Некорректные поля коэффициента ресурса'; end if;
    if not exists(select 1 from jsonb_array_elements(old_config->'resources') old where old->>'name'=item->>'name'
      and old->'category'=item->'category' and old->'showInProduction'=item->'showInProduction') then raise sqlstate '22023' using message='Изменены сведения о ресурсе'; end if;
    foreach key_name in array array['value','production','consumption'] loop
      if jsonb_typeof(item->key_name) is distinct from 'number' or (item->>key_name)::numeric<0 or (item->>key_name)::numeric>1000000 then raise sqlstate '22023' using message='Параметр ресурса должен быть числом от 0 до 1000000'; end if;
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
