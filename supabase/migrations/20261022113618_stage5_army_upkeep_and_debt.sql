-- Stage 5: configurable army upkeep, treasury shortfall tracking, and auditable cash movements.

create table if not exists fauxlore.army_unit_types (
  id bigint generated always as identity primary key,
  name text not null unique check(length(btrim(name)) between 1 and 80),
  upkeep_per_unit numeric(14,2) not null default 0 check(upkeep_per_unit>=0),
  updated_by bigint references fauxlore.accounts(id),
  updated_at timestamptz not null default now()
);
create table if not exists fauxlore.state_army_units (
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  unit_type_id bigint not null references fauxlore.army_unit_types(id),
  quantity integer not null check(quantity>=0),
  primary key(state_id,unit_type_id)
);
create table if not exists fauxlore.state_treasury_debts (
  state_id integer primary key references fauxlore.state_profiles(state_id) on delete cascade,
  balance numeric(14,2) not null default 0 check(balance>=0),
  updated_at timestamptz not null default now()
);
create table if not exists fauxlore.state_budget_ledger (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check(estate='Корона'),
  year integer not null,
  turn integer not null,
  kind text not null check(kind in ('army_upkeep','debt_repayment')),
  unit_type_id bigint references fauxlore.army_unit_types(id) on delete set null,
  cash_delta numeric(14,2) not null,
  debt_delta numeric(14,2) not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(state_id,year,turn,kind,unit_type_id)
);
alter table fauxlore.army_unit_types enable row level security;
alter table fauxlore.state_army_units enable row level security;
alter table fauxlore.state_treasury_debts enable row level security;
alter table fauxlore.state_budget_ledger enable row level security;
revoke all on fauxlore.army_unit_types,fauxlore.state_army_units,fauxlore.state_treasury_debts,fauxlore.state_budget_ledger from public,anon,authenticated;
insert into fauxlore.state_treasury_debts(state_id) select state_id from fauxlore.state_profiles on conflict do nothing;

-- Keep this initializer in sync so approved/new states get a debt row as well.
create or replace function fauxlore.initialize_state_treasuries()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into fauxlore.state_treasuries(state_id,estate,balance) values
    (new.state_id,'Корона',15000),(new.state_id,'Знать',3000),(new.state_id,'Духовенство',3000),
    (new.state_id,'Горожане',3000),(new.state_id,'Крестьяне',3000)
  on conflict(state_id,estate) do nothing;
  insert into fauxlore.state_treasury_debts(state_id) values(new.state_id) on conflict(state_id) do nothing;
  update fauxlore.state_profiles set treasury=(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=new.state_id)
  where state_id=new.state_id;
  return new;
end $$;
revoke all on function fauxlore.initialize_state_treasuries() from public,anon,authenticated;

create or replace function fauxlore.army_budget_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_value integer; prior fauxlore.operations; fingerprint text;
  result jsonb; item jsonb; unit_name text; quantity_value integer; unit_type_id_value bigint; rate_value numeric;
begin
  if path !~ '^admin/states/[0-9]+/army$' or method not in ('GET','PATCH') or jsonb_typeof(body) is distinct from 'object' then
    raise sqlstate '22023' using message='Некорректный запрос состава армии';
  end if;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  state_value:=split_part(path,'/',3)::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_value) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if method='GET' then
    select jsonb_build_object('state_id',state_value,'state_name',c.name,
      'treasury',(select balance from fauxlore.state_treasuries where state_id=state_value and estate='Корона'),
      'debt',(select coalesce(balance,0) from fauxlore.state_treasury_debts where state_id=state_value),
      'units',coalesce((select jsonb_agg(jsonb_build_object('name',t.name,'quantity',u.quantity,'upkeep_per_unit',t.upkeep_per_unit) order by t.name)
        from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id where u.state_id=state_value),'[]'::jsonb))
      into result from fauxlore.map_categories c where c.layer='states' and c.id=state_value;
    return result;
  end if;
  if request_id is null or body-array['units']<>'{}' or jsonb_typeof(body->'units') is distinct from 'array' or jsonb_array_length(body->'units')>100 then
    raise sqlstate '22023' using message='Передайте до 100 типов частей';
  end if;
  if exists(select 1 from jsonb_array_elements(body->'units') e(value)
      where jsonb_typeof(value) is distinct from 'object' or value-array['name','quantity','upkeep_per_unit']<>'{}'
        or jsonb_typeof(value->'name') is distinct from 'string' or jsonb_typeof(value->'quantity') is distinct from 'number'
        or jsonb_typeof(value->'upkeep_per_unit') is distinct from 'number'
        or length(btrim(value->>'name')) not between 1 and 80 or (value->>'quantity')!~'^\d+$'
        or (value->>'quantity')::numeric>1000000 or (value->>'upkeep_per_unit')::numeric<0 or (value->>'upkeep_per_unit')::numeric>1000000) then
    raise sqlstate '22023' using message='Проверьте название, количество и содержание частей';
  end if;
  if exists(select lower(value->>'name') from jsonb_array_elements(body->'units') e(value) group by lower(value->>'name') having count(*)>1) then
    raise sqlstate '22023' using message='Типы частей не должны повторяться';
  end if;
  if coalesce((select sum((value->>'quantity')::numeric*(value->>'upkeep_per_unit')::numeric)
      from jsonb_array_elements(body->'units') e(value)),0)>999999999999.99 then
    raise sqlstate '22023' using message='Общая стоимость армии превышает допустимый предел';
  end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into prior from fauxlore.operations o where o.account_id=a.id and o.request_id=army_budget_api.request_id;
  if found then
    if prior.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return prior.result;
  end if;
  perform 1 from fauxlore.state_profiles where state_id=state_value for update;
  delete from fauxlore.state_army_units where state_id=state_value;
  for item in select value from jsonb_array_elements(body->'units') loop
    unit_name:=btrim(item->>'name'); quantity_value:=(item->>'quantity')::integer; rate_value:=(item->>'upkeep_per_unit')::numeric;
    insert into fauxlore.army_unit_types(name,upkeep_per_unit,updated_by,updated_at)
      values(unit_name,rate_value,a.id,now())
      on conflict(name) do update set upkeep_per_unit=excluded.upkeep_per_unit,updated_by=excluded.updated_by,updated_at=now()
      returning id into unit_type_id_value;
    if (item->>'quantity')::integer>0 then
      insert into fauxlore.state_army_units(state_id,unit_type_id,quantity) values(state_value,unit_type_id_value,(item->>'quantity')::integer);
    end if;
  end loop;
  select jsonb_build_object('state_id',state_value,'state_name',c.name,
      'treasury',(select balance from fauxlore.state_treasuries where state_id=state_value and estate='Корона'),
      'debt',(select coalesce(balance,0) from fauxlore.state_treasury_debts where state_id=state_value),
      'units',coalesce((select jsonb_agg(jsonb_build_object('name',t.name,'quantity',u.quantity,'upkeep_per_unit',t.upkeep_per_unit) order by t.name)
        from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id where u.state_id=state_value),'[]'::jsonb))
    into result from fauxlore.map_categories c where c.layer='states' and c.id=state_value;
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.army_budget_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.army_budget_api(text,text,jsonb,uuid) to anon,authenticated;

create or replace function fauxlore.charge_army_upkeep_before_turn()
returns trigger language plpgsql security definer set search_path='' as $$
declare report_value jsonb; report_item jsonb; report_name text; report_array jsonb; state_row record; unit_row record;
  crown_balance numeric; debt_balance numeric; debt_paid numeric; expense_total numeric; expense_paid numeric;
  available numeric; line_cost numeric; line_paid numeric; remaining_cost numeric; remaining_cash numeric;
  unpaid numeric; new_treasury numeric; details jsonb; item_index integer; item_count integer;
begin
  if new.year=old.year and new.turn=old.turn then return new; end if;
  select report into report_value from fauxlore.turn_economy_reports where year=old.year and turn=old.turn for update;
  if report_value is null then raise sqlstate '22023' using message='Не найден налоговый отчёт для расчётного хода'; end if;
  for state_row in
    select u.state_id,c.name state_name,round(sum(u.quantity*t.upkeep_per_unit),2) expense_total,
      jsonb_agg(jsonb_build_object('unit_type_id',t.id,'name',t.name,'quantity',u.quantity,'upkeep_per_unit',t.upkeep_per_unit,
        'cost',round(u.quantity*t.upkeep_per_unit,2)) order by t.name) units
    from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id
    join fauxlore.map_categories c on c.layer='states' and c.id=u.state_id
    where u.quantity>0 group by u.state_id,c.name having sum(u.quantity*t.upkeep_per_unit)>0
    union
    select d.state_id,c.name,0::numeric,'[]'::jsonb
    from fauxlore.state_treasury_debts d join fauxlore.map_categories c on c.layer='states' and c.id=d.state_id
    where d.balance>0 and not exists(select 1 from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id
      where u.state_id=d.state_id and u.quantity>0 and t.upkeep_per_unit>0)
    order by 1
  loop
    insert into fauxlore.state_treasury_debts(state_id) values(state_row.state_id) on conflict(state_id) do nothing;
    select balance into crown_balance from fauxlore.state_treasuries where state_id=state_row.state_id and estate='Корона' for update;
    select balance into debt_balance from fauxlore.state_treasury_debts where state_id=state_row.state_id for update;
    debt_paid:=least(crown_balance,debt_balance);
    if debt_paid>0 then
      update fauxlore.state_treasuries set balance=balance-debt_paid,updated_at=now() where state_id=state_row.state_id and estate='Корона';
      update fauxlore.state_treasury_debts set balance=balance-debt_paid,updated_at=now() where state_id=state_row.state_id;
      insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
        values(state_row.state_id,'Корона',old.year,old.turn,'debt_repayment',-debt_paid,-debt_paid,jsonb_build_object('amount',debt_paid));
      crown_balance:=crown_balance-debt_paid; debt_balance:=debt_balance-debt_paid;
    end if;
    expense_total:=state_row.expense_total; available:=crown_balance;
    remaining_cost:=expense_total; remaining_cash:=least(available,expense_total);
    select count(*) into item_count from jsonb_array_elements(state_row.units);
    details:='[]'::jsonb; item_index:=0;
    for unit_row in select value from jsonb_array_elements(state_row.units) e(value) loop
      item_index:=item_index+1; line_cost:=(unit_row.value->>'cost')::numeric;
      if expense_total<=available then line_paid:=line_cost;
      elsif item_index=item_count then line_paid:=remaining_cash;
      else line_paid:=least(line_cost,round(remaining_cash*line_cost/remaining_cost,2)); end if;
      line_paid:=least(line_cost,line_paid,remaining_cash);
      unpaid:=line_cost-line_paid; remaining_cash:=remaining_cash-line_paid; remaining_cost:=remaining_cost-line_cost;
      details:=details||jsonb_build_array(unit_row.value||jsonb_build_object('paid',line_paid,'arrears',unpaid));
      insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,unit_type_id,cash_delta,debt_delta,details)
        values(state_row.state_id,'Корона',old.year,old.turn,'army_upkeep',(unit_row.value->>'unit_type_id')::bigint,-line_paid,unpaid,
          unit_row.value||jsonb_build_object('paid',line_paid,'arrears',unpaid));
    end loop;
    expense_paid:=least(available,expense_total); unpaid:=expense_total-expense_paid;
    if expense_paid>0 then update fauxlore.state_treasuries set balance=balance-expense_paid,updated_at=now() where state_id=state_row.state_id and estate='Корона'; end if;
    if unpaid>0 then update fauxlore.state_treasury_debts set balance=balance+unpaid,updated_at=now() where state_id=state_row.state_id; end if;
    update fauxlore.state_profiles sp set treasury=(select coalesce(sum(st.balance),0) from fauxlore.state_treasuries st where st.state_id=sp.state_id)
      where sp.state_id=state_row.state_id;
    select coalesce(sum(balance),0) into new_treasury from fauxlore.state_treasuries where state_id=state_row.state_id;
    select coalesce(balance,0) into debt_balance from fauxlore.state_treasury_debts where state_id=state_row.state_id;
    report_name:=state_row.state_name;
    report_item:=jsonb_build_object('id',state_row.state_id,'name',report_name,'province_count',0,'gross_taxes',0,'crown_taxes',0,
      'estate_taxes',0,'tax_buckets',jsonb_build_object('Корона',crown_balance),'tax_details','[]'::jsonb);
    if exists(select 1 from jsonb_array_elements(report_value) x(value) where (value->>'id')::integer=state_row.state_id) then
      select value into report_item from jsonb_array_elements(report_value) x(value) where (value->>'id')::integer=state_row.state_id limit 1;
      report_array:=(select coalesce(jsonb_agg(case when (value->>'id')::integer=state_row.state_id then
        value||jsonb_build_object('tax_buckets',coalesce(value->'tax_buckets','{}'::jsonb)||jsonb_build_object('Корона',crown_balance),
          'army_upkeep',expense_total,'army_upkeep_paid',expense_paid,'army_upkeep_arrears',unpaid,'debt_repaid',debt_paid,
          'treasury_debt',debt_balance,'closing_treasury',new_treasury,'army_details',details)
        else value end order by ord),'[]'::jsonb) from jsonb_array_elements(report_value) with ordinality x(value,ord));
    else
      report_array:=report_value||jsonb_build_array(report_item||jsonb_build_object('army_upkeep',expense_total,'army_upkeep_paid',expense_paid,
        'army_upkeep_arrears',unpaid,'debt_repaid',debt_paid,'treasury_debt',debt_balance,'closing_treasury',new_treasury,'army_details',details));
    end if;
    report_value:=report_array;
  end loop;
  update fauxlore.turn_economy_reports set report=report_value where year=old.year and turn=old.turn;
  return new;
end $$;
revoke all on function fauxlore.charge_army_upkeep_before_turn() from public,anon,authenticated;
drop trigger if exists game_calendar_charge_army_upkeep on fauxlore.game_calendar;
create trigger game_calendar_charge_army_upkeep before update of year,turn on fauxlore.game_calendar
for each row execute function fauxlore.charge_army_upkeep_before_turn();

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if path='map/revision' and method='GET' then return fauxlore.map_revision();
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
  elsif path ~ '^admin/states/[0-9]+/army$' then return fauxlore.army_budget_api(path,method,body,request_id);
  elsif path='game/calendar' or path='admin/turn/advance' then return fauxlore.turn_api(path,method,body,request_id);
  elsif path='admin/states' then return fauxlore.state_api(path,method,body,request_id);
  elsif path='my/states' or path like 'admin/states/%' then return fauxlore.game_state_api(path,method,body,request_id);
  else return fauxlore.api(path,method,body,request_id); end if;
end $$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
