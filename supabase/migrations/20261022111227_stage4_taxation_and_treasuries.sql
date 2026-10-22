-- Stage 4: calculate provincial taxes from authoritative database values,
-- split receipts between the Crown and the estate, and credit state treasuries.

update fauxlore.economy_parameters
set config=config||jsonb_build_object('estateTaxGreed',jsonb_build_object(
  'Господствующее|Корона',0,'Господствующее|Знать',0.60,'Господствующее|Духовенство',0.50,'Господствующее|Горожане',0.50,'Господствующее|Крестьяне',0.40,
  'Ключевое|Корона',0,'Ключевое|Знать',0.35,'Ключевое|Духовенство',0.30,'Ключевое|Горожане',0.30,'Ключевое|Крестьяне',0.20,
  'Значимое|Корона',0,'Значимое|Знать',0.20,'Значимое|Духовенство',0.15,'Значимое|Горожане',0.15,'Значимое|Крестьяне',0.10,
  'Бесправное|Корона',0,'Бесправное|Знать',0.05,'Бесправное|Духовенство',0.05,'Бесправное|Горожане',0.05,'Бесправное|Крестьяне',0
)) where singleton=true;

create table if not exists fauxlore.state_treasuries (
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check(estate in ('Корона','Знать','Духовенство','Горожане','Крестьяне')),
  balance numeric(14,2) not null default 0 check(balance>=0),
  updated_at timestamptz not null default now(),
  primary key(state_id,estate)
);
alter table fauxlore.state_treasuries enable row level security;
revoke all on fauxlore.state_treasuries from public,anon,authenticated;

create or replace function fauxlore.initialize_state_treasuries()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into fauxlore.state_treasuries(state_id,estate,balance) values
    (new.state_id,'Корона',15000),(new.state_id,'Знать',3000),(new.state_id,'Духовенство',3000),
    (new.state_id,'Горожане',3000),(new.state_id,'Крестьяне',3000)
  on conflict(state_id,estate) do nothing;
  update fauxlore.state_profiles set treasury=(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=new.state_id)
  where state_id=new.state_id;
  return new;
end $$;
revoke all on function fauxlore.initialize_state_treasuries() from public,anon,authenticated;
drop trigger if exists state_profiles_initialize_treasuries on fauxlore.state_profiles;
create trigger state_profiles_initialize_treasuries after insert on fauxlore.state_profiles
for each row execute function fauxlore.initialize_state_treasuries();

-- Existing states receive the same agreed starting balances as newly approved states.
insert into fauxlore.state_treasuries(state_id,estate,balance)
select s.state_id,e.estate,e.balance
from fauxlore.state_profiles s
cross join (values ('Корона',15000::numeric),('Знать',3000::numeric),('Духовенство',3000::numeric),('Горожане',3000::numeric),('Крестьяне',3000::numeric)) e(estate,balance)
on conflict(state_id,estate) do nothing;
update fauxlore.state_profiles s set treasury=t.total
from (select state_id,sum(balance)::numeric(14,2) total from fauxlore.state_treasuries group by state_id) t
where t.state_id=s.state_id;

create or replace function fauxlore.split_province_tax(gross numeric,belonging text,status text,cfg jsonb)
returns table(crown numeric,estate numeric) language plpgsql immutable set search_path='' as $$
declare greed numeric;
begin
  if gross is null or gross<0 then raise sqlstate '22023' using message='Сумма налога не может быть отрицательной'; end if;
  if belonging is null or belonging='Отсутствует' then return query select round(gross,2),0::numeric; return; end if;
  if belonging not in ('Корона','Знать','Духовенство','Горожане','Крестьяне') or status not in ('Господствующее','Ключевое','Значимое','Бесправное') then
    raise sqlstate '22023' using message='Неизвестное сословие или его статус';
  end if;
  greed:=nullif(cfg#>>array['estateTaxGreed',status||'|'||belonging],'')::numeric;
  if greed is null or greed<0 or greed>1 then raise sqlstate '22023' using message='Не задан корректный коэффициент распределения налога'; end if;
  return query select round(gross*(1-greed),2),gross-round(gross*(1-greed),2);
end $$;
revoke all on function fauxlore.split_province_tax(numeric,text,text,jsonb) from public,anon,authenticated;

create or replace function fauxlore.turn_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; calendar_row fauxlore.game_calendar; previous fauxlore.operations;
  fingerprint text; result jsonb; cfg jsonb; tax_rows jsonb; state_rows jsonb; states_count integer:=0;
  province_row record; tax_gross numeric; crown_tax numeric; estate_tax numeric; status_value text;
  beneficiary_id integer; beneficiary_name text; tax_share numeric; expected_year integer; expected_turn integer;
  report_value jsonb:='[]'::jsonb;
begin
  if path='game/calendar' and method='GET' then
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    return jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn);
  end if;
  if path<>'admin/turn/advance' or method<>'POST' or jsonb_typeof(body) is distinct from 'object' or
    body-array['expected_year','expected_turn','report']<>'{}' or
    jsonb_typeof(body->'expected_year') is distinct from 'number' or jsonb_typeof(body->'expected_turn') is distinct from 'number' then
    raise sqlstate '22023' using message='Некорректный запрос смены хода';
  end if;
  if (body->>'expected_year')!~'^\d+$' or (body->>'expected_turn')!~'^\d+$' then
    raise sqlstate '22023' using message='Ожидаемые год и ход должны быть целыми числами';
  end if;
  if body ? 'report' and (jsonb_typeof(body->'report') is distinct from 'array' or octet_length((body->'report')::text)>1500000) then
    raise sqlstate '22023' using message='Некорректный запрос смены хода';
  end if;
  expected_year:=(body->>'expected_year')::integer; expected_turn:=(body->>'expected_turn')::integer;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=turn_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true for update;
  if calendar_row.year<>expected_year or calendar_row.turn<>expected_turn then
    raise sqlstate '40001' using message='Ход уже изменён в другой сессии. Обновите страницу и повторите.';
  end if;
  select config into cfg from fauxlore.economy_parameters where singleton=true for share;

  create temporary table if not exists pg_temp.turn_tax_lines(
    province_id integer, province_name text, recipient_id integer, recipient_name text,
    belonging text, gross numeric, crown numeric, estate numeric
  ) on commit drop;
  truncate pg_temp.turn_tax_lines;
  for province_row in
    select p.id,p.name,p.population,p.province_type,p.control,p.occupation,
      race.name race_name,religion.name religion_name,owner.id owner_id,owner.name owner_name,
      occupier.id occupier_id,occupier.name occupier_name,
      p.belonging
    from fauxlore.provinces p
    left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
    left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id
    left join fauxlore.province_values relv on relv.province_id=p.id and relv.layer='religions'
    left join fauxlore.map_categories religion on religion.layer='religions' and religion.id=relv.category_id
    left join fauxlore.province_values ov on ov.province_id=p.id and ov.layer='states'
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=ov.category_id
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    where p.kind='land' and (ov.category_id is not null or p.occupation is not null)
    order by p.id
  loop
    if province_row.occupation is not null and (province_row.owner_id is null or lower(province_row.occupation)<>lower(province_row.owner_name)) then
      beneficiary_id:=province_row.occupier_id; beneficiary_name:=province_row.occupier_name; tax_share:=.5;
      if beneficiary_id is null then raise sqlstate '22023' using message='Не найдено государство-оккупант провинции '||province_row.id; end if;
    else
      beneficiary_id:=province_row.owner_id; beneficiary_name:=province_row.owner_name; tax_share:=1;
    end if;
    if beneficiary_id is null then continue; end if;
    if province_row.race_name is null or province_row.religion_name is null then
      raise sqlstate '22023' using message='Для провинции '||province_row.id||' не заданы раса или религия'; end if;
    if nullif(cfg#>>array['provinceModifiers',province_row.province_type,'tax'],'') is null or
       nullif(cfg#>>array['raceTaxRates',province_row.race_name],'') is null or
       nullif(cfg#>>array['religionTaxRates',province_row.religion_name],'') is null then
      raise sqlstate '22023' using message='Не заданы налоговые коэффициенты провинции '||province_row.id; end if;
    if coalesce(province_row.control,100)<0 or coalesce(province_row.control,100)>100 then
      raise sqlstate '22023' using message='Контроль провинции должен быть от 0 до 100'; end if;
    tax_gross:=round(greatest(0,province_row.population)::numeric/10 *
      ((cfg#>>array['raceTaxRates',province_row.race_name])::numeric+(cfg#>>array['religionTaxRates',province_row.religion_name])::numeric) *
      (cfg#>>array['provinceModifiers',province_row.province_type,'tax'])::numeric *
      coalesce(province_row.control,100)::numeric/100 * tax_share,2);
    beneficiary_id:=case when province_row.occupation is not null and tax_share=.5 then province_row.occupier_id else province_row.owner_id end;
    if beneficiary_id is null then continue; end if;
    if province_row.belonging is null or province_row.belonging='Отсутствует' then
      select crown,estate into crown_tax,estate_tax from fauxlore.split_province_tax(tax_gross,'Отсутствует',null,cfg);
    else
      status_value:=fauxlore.estate_status_for(beneficiary_id,province_row.belonging);
      select crown,estate into crown_tax,estate_tax from fauxlore.split_province_tax(tax_gross,province_row.belonging,status_value,cfg);
    end if;
    insert into pg_temp.turn_tax_lines values(province_row.id,province_row.name,beneficiary_id,beneficiary_name,
      coalesce(province_row.belonging,'Отсутствует'),tax_gross,crown_tax,estate_tax);
  end loop;

  with receipts as (
    select recipient_id,'Корона'::text estate,sum(crown)::numeric(14,2) amount from pg_temp.turn_tax_lines group by recipient_id
    union all
    select recipient_id,belonging,sum(estate)::numeric(14,2) from pg_temp.turn_tax_lines where belonging<>'Отсутствует' group by recipient_id,belonging
  )
  insert into fauxlore.state_treasuries(state_id,estate,balance)
  select recipient_id,estate,amount from receipts where amount<>0
  on conflict(state_id,estate) do update set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
  update fauxlore.state_profiles sp set treasury=(select coalesce(sum(st.balance),0) from fauxlore.state_treasuries st where st.state_id=sp.state_id)
  where exists(select 1 from pg_temp.turn_tax_lines l where l.recipient_id=sp.state_id);

  select coalesce(jsonb_agg(state_report order by state_report->>'name'),'[]'::jsonb),count(*)::integer
    into report_value,states_count
  from (
    select jsonb_build_object(
      'id',s.recipient_id,'name',s.recipient_name,
      'province_count',count(distinct l.province_id),
      'gross_taxes',round(coalesce(sum(l.gross),0),2),
      'crown_taxes',round(coalesce(sum(l.crown),0),2),
      'estate_taxes',round(coalesce(sum(l.estate),0),2),
      'tax_buckets',coalesce((select jsonb_object_agg(st.estate,round(st.balance,2)) from fauxlore.state_treasuries st where st.state_id=s.id),'{}'::jsonb),
      'opening_treasury',round(coalesce((select sum(st.balance) from fauxlore.state_treasuries st where st.state_id=s.id),0)-coalesce(sum(l.crown+l.estate),0),2),
      'closing_treasury',round(coalesce((select sum(st.balance) from fauxlore.state_treasuries st where st.state_id=s.id),0),2),
      'tax_details',coalesce(jsonb_agg(jsonb_build_object('province_id',l.province_id,'province_name',l.province_name,
        'belonging',l.belonging,'gross',l.gross,'crown',l.crown,'estate',l.estate) order by l.province_id)
        filter(where l.province_id is not null),'[]'::jsonb)
    ) state_report
    from (select distinct recipient_id,recipient_name from pg_temp.turn_tax_lines) s
    left join pg_temp.turn_tax_lines l on l.recipient_id=s.recipient_id
    group by s.recipient_id,s.recipient_name
  ) reports;
  insert into fauxlore.turn_economy_reports(year,turn,report,created_by)
    values(calendar_row.year,calendar_row.turn,report_value,a.id);

  -- Keep the established annual character lifecycle within this same atomic turn.
  for province_row in
    select ch.id,ch.state_id,ch.age,ch.name,ch.surname,ch.is_current_ruler,coalesce(rc.name,'') race_name
    from fauxlore.state_characters ch left join fauxlore.map_categories rc on rc.layer='races' and rc.id=ch.race_id
    where ch.alive order by ch.id for update of ch
  loop
    declare age_value integer; death_chance numeric; died boolean;
    begin
      age_value:=least(250,province_row.age+1);
      death_chance:=case
        when province_row.race_name in ('Люди','Полуэльфы','Зверолюди') then case when age_value<60 then 0 when age_value<=70 then .05 when age_value<=80 then .15 when age_value<=90 then .25 when age_value<=100 then .50 else .70 end
        when province_row.race_name='Дварфы' then case when age_value<80 then 0 when age_value<=90 then .05 when age_value<=100 then .15 when age_value<=110 then .25 when age_value<=120 then .50 else .70 end
        when province_row.race_name='Эльфы' then case when age_value<100 then 0 when age_value<=120 then .05 when age_value<=140 then .15 when age_value<=160 then .25 when age_value<=180 then .50 else .70 end
        else 0 end;
      died:=death_chance>0 and random()<death_chance;
      update fauxlore.state_characters set age=age_value,alive=not died,
        died_at_turn=case when died then calendar_row.turn else died_at_turn end,
        is_current_ruler=case when died and province_row.is_current_ruler then false else is_current_ruler end where id=province_row.id;
      if died and province_row.is_current_ruler then
        insert into fauxlore.notifications(account_id,kind,title,message)
        select recipients.account_id,'ruler_death','Умер правитель государства',
          'Правитель '||trim(province_row.name||' '||province_row.surname)||' умер в возрасте '||age_value||' лет. Требуется провести передачу власти.'
        from (
          select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=province_row.state_id
          union
          select ac.id from fauxlore.accounts ac where ac.role='admin'
            and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=province_row.state_id)
        ) recipients;
      end if;
    end;
  end loop;
  update fauxlore.game_calendar set year=year+1,turn=turn+1,updated_at=now() where singleton=true returning * into calendar_row;
  result:=jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn,
    'calculated_year',calendar_row.year-1,'calculated_turn',calendar_row.turn-1,'states_calculated',states_count);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,turn_api.request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.turn_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.turn_api(text,text,jsonb,uuid) to anon,authenticated;

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
  foreach key_name in array array['raceTaxRates','religionTaxRates','tradeStatusModifiers','raceGrowthModifiers','recruitGrowthModifiers','recruitLimitModifiers','estateRecruitModifiers','provinceValueWeights','estateTaxGreed'] loop
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
  insert into fauxlore.economy_parameter_history(account_id,before_config,after_config) values(a.id,old_config,next_config);
  update fauxlore.economy_parameters set config=next_config,updated_at=now() where singleton=true;
  result:=jsonb_build_object('config',next_config);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.economy_config_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.economy_config_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
