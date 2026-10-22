-- Stage 2: guarded admin editor and audited economy parameter updates.
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
      if jsonb_typeof(pair.value)<>'number' or (pair.value#>>'{}')::numeric<0 or (pair.value#>>'{}')::numeric>10000 then
        raise sqlstate '22023' using message='Коэффициент должен быть числом от 0 до 10000'; end if;
    end loop;
  end loop;
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
    if not exists(select 1 from jsonb_array_elements(old_config->'resources') old where old->>'name'=item->>'name'
      and old->'category'=item->'category' and old->'showInProduction'=item->'showInProduction') then raise sqlstate '22023' using message='Изменены сведения о ресурсе'; end if;
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


create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if path='map/revision' and method='GET' then return fauxlore.map_revision();
  elsif path in ('economy/config','admin/economy/config') then return fauxlore.economy_config_api(path,method,body,request_id);
  elsif path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then return fauxlore.character_lifecycle_api(path,method,body,request_id);
  elsif path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$' then return fauxlore.characters_api(path,method,body,request_id);
  elsif path='my/marriage-offers' or path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then return fauxlore.dynastic_marriage_api(path,method,body,request_id);
  elsif path ~ '^(my|admin)/states/[0-9]+/abdicate$' then return fauxlore.abdicate_api(path,method,body,request_id);
  elsif path ~ '^(my|admin)/states/[0-9]+/(succession(/events/[0-9]+/choose)?|politics|designate)$' then return fauxlore.succession_api(path,method,body,request_id);
  elsif path='my/applications' and method='GET' then return fauxlore.my_applications();
  elsif path='my/applications' and method='POST' then return fauxlore.registration_api_with_surname(path,method,body,request_id);
  elsif path ~ '^admin/applications/[0-9]+$' and method='PATCH' then return fauxlore.registration_api_with_surname(path,method,body,request_id);
  elsif path='my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%' then return fauxlore.registration_api(path,method,body,request_id);
  elsif path ~ '^my/applications/[0-9]+$' then return fauxlore.application_details(path,method,body);
  elsif path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then return fauxlore.state_emblem_api(path,method,body,request_id);
  elsif path='game/calendar' or path='admin/turn/advance' then return fauxlore.turn_api(path,method,body,request_id);
  elsif path='admin/states' then return fauxlore.state_api(path,method,body,request_id);
  elsif path='my/states' or path like 'admin/states/%' then return fauxlore.game_state_api(path,method,body,request_id);
  else return fauxlore.api(path,method,body,request_id);
  end if;
end;
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';

-- Expose only the compact revision token through a dedicated public RPC.
create or replace function public.map_revision_api()
returns jsonb language sql stable security invoker set search_path='' as $$
  select fauxlore.map_revision()
$$;
revoke all on function public.map_revision_api() from public;
grant execute on function public.map_revision_api() to anon,authenticated;
notify pgrst,'reload schema';
