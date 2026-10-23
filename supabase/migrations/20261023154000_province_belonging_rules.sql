-- Every land province belongs to an estate; newly acquired land starts with the Crown.
do $$ begin
  if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
    raise exception 'Finish or roll back the active test turn before applying belonging rules';
  end if;
end $$;
update fauxlore.provinces set belonging='Корона' where belonging='Отсутствует';
alter table fauxlore.provinces alter column belonging set default 'Корона';
alter table fauxlore.provinces drop constraint if exists provinces_belonging_check;
alter table fauxlore.provinces add constraint provinces_belonging_check
  check(belonging in ('Корона','Знать','Духовенство','Горожане','Крестьяне'));

create or replace function fauxlore.enforce_province_belonging()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.belonging='Отсутствует' or new.belonging is null then
    raise sqlstate '22023' using message='Укажите сословие провинции';
  end if;
  if new.has_capital_marker and new.belonging<>'Корона' then
    raise sqlstate '22023' using message='Столица всегда принадлежит Короне';
  end if;
  return new;
end $$;
revoke all on function fauxlore.enforce_province_belonging() from public,anon,authenticated;
drop trigger if exists provinces_enforce_belonging on fauxlore.provinces;
create trigger provinces_enforce_belonging before insert or update of belonging,has_capital_marker
on fauxlore.provinces for each row execute function fauxlore.enforce_province_belonging();

do $$
declare fn text;
begin
  fn:=pg_get_functiondef('fauxlore.normalize(text,jsonb)'::regprocedure);
  if position('''Крестьяне'',''Отсутствует''' in fn)=0 then raise exception 'Belonging validation marker missing'; end if;
  execute replace(fn,'''Крестьяне'',''Отсутствует''','''Крестьяне''');
end $$;

create or replace function fauxlore.assign_acquired_province_to_crown()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.layer='states' and (tg_op='INSERT' or new.category_id is distinct from old.category_id) then
    update fauxlore.provinces set belonging='Корона' where id=new.province_id and kind='land';
  end if;
  return new;
end $$;
revoke all on function fauxlore.assign_acquired_province_to_crown() from public,anon,authenticated;
drop trigger if exists province_values_crown_acquisition on fauxlore.province_values;
create trigger province_values_crown_acquisition after insert or update of category_id
on fauxlore.province_values for each row execute function fauxlore.assign_acquired_province_to_crown();

-- Initial allocation follows the founding principles via estate status. The
-- highest-ranked estates share non-capital provinces in stable ID order.
create or replace function fauxlore.allocate_new_state_belonging()
returns trigger language plpgsql security definer set search_path='' as $$
declare selected text[]; province_row record; index_value integer:=0;
begin
  if new.status<>'Принято' or old.status='Принято' then return new; end if;
  select array_agg(name order by name) into selected from (
    select name,case fauxlore.estate_status_for(new.state_id,name)
      when 'Господствующее' then 4 when 'Ключевое' then 3
      when 'Значимое' then 2 else 1 end rank
    from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) name
  ) e where rank=(select max(case fauxlore.estate_status_for(new.state_id,x)
      when 'Господствующее' then 4 when 'Ключевое' then 3 when 'Значимое' then 2 else 1 end)
      from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) x);
  for province_row in select p.id from fauxlore.provinces p
    join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=new.state_id
    where p.kind='land' and p.id<>new.capital_province_id order by p.id loop
    index_value:=index_value+1;
    update fauxlore.provinces set belonging=selected[1+(index_value-1)%array_length(selected,1)] where id=province_row.id;
  end loop;
  update fauxlore.provinces set belonging='Корона' where id=new.capital_province_id;
  return new;
end $$;
revoke all on function fauxlore.allocate_new_state_belonging() from public,anon,authenticated;
drop trigger if exists state_application_allocate_belonging on fauxlore.state_applications;
create trigger state_application_allocate_belonging after update of status on fauxlore.state_applications
for each row execute function fauxlore.allocate_new_state_belonging();

create or replace function fauxlore.province_belonging_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; state_key integer; province_key integer; province_row fauxlore.provinces;
  previous fauxlore.operations; old_estate text; new_estate text; fp text; result jsonb;
begin
  actor:=fauxlore.current_account();
  if path !~ '^(my|admin)/states/[0-9]+/provinces/[0-9]+/belonging$' then
    raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if path like 'admin/%' and actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  state_key:=split_part(path,'/',3)::integer; province_key:=split_part(path,'/',5)::integer;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
    where account_id=actor.id and layer='states' and state_id=state_key) then
    raise sqlstate '42501' using message='Нет прав на государство'; end if;
  select p.* into province_row from fauxlore.provinces p
    join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=state_key
    where p.id=province_key and p.kind='land' for update of p;
  if not found then raise sqlstate 'P0002' using message='Провинция государства не найдена'; end if;
  if method='GET' then return jsonb_build_object('province_id',province_key,'belonging',province_row.belonging,'capital',province_row.has_capital_marker); end if;
  if method not in ('POST','PATCH') or request_id is null or jsonb_typeof(body) is distinct from 'object'
    or body-'belonging'<>'{}'::jsonb then raise sqlstate '22023' using message='Укажите новую принадлежность'; end if;
  new_estate:=body->>'belonging'; old_estate:=province_row.belonging;
  if new_estate is null or new_estate not in ('Корона','Знать','Духовенство','Горожане','Крестьяне') then
    raise sqlstate '22023' using message='Неизвестное сословие'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=actor.id and o.request_id=province_belonging_api.request_id;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  if found then
    if previous.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  if new_estate<>old_estate then
    if province_row.has_capital_marker then raise sqlstate '22023' using message='Столицу нельзя передать'; end if;
    update fauxlore.provinces set belonging=new_estate where id=province_key;
    perform fauxlore.ensure_state_group_politics(state_key);
    update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-case when new_estate='Корона' then .10 else .05 end)
      where state_id=state_key and group_type='estate' and group_key=old_estate;
    update fauxlore.state_group_politics set loyalty=least(1,loyalty+.05)
      where state_id=state_key and group_type='estate' and group_key=new_estate;
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  end if;
  result:=jsonb_build_object('province_id',province_key,'previous',old_estate,'belonging',new_estate,'changed',new_estate<>old_estate);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(actor.id,province_belonging_api.request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.province_belonging_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.province_belonging_api(text,text,jsonb,uuid) to authenticated;

do $$
declare fn text;
begin
  fn:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  fn:=replace(fn,'if path ~ ''^(my|admin)/states/[0-9]+/trade-duty$'' then',
    'if path ~ ''^(my|admin)/states/[0-9]+/provinces/[0-9]+/belonging$'' then return fauxlore.province_belonging_api(path,method,body,request_id);'||chr(10)||
    '  elsif path ~ ''^(my|admin)/states/[0-9]+/trade-duty$'' then');
  execute fn;
end $$;
notify pgrst,'reload schema';
