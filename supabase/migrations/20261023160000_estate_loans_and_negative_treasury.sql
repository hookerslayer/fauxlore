-- The former technical arrears become a negative Crown balance. No money is created.
do $$ begin
  if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
    raise exception 'Finish or roll back the active test turn before changing debt rules';
  end if;
end $$;
alter table fauxlore.state_treasuries drop constraint if exists state_treasuries_balance_check;
update fauxlore.state_treasuries t set balance=t.balance-d.balance,updated_at=now()
  from fauxlore.state_treasury_debts d where t.state_id=d.state_id and t.estate='Корона' and d.balance>0;
update fauxlore.state_treasury_debts set balance=0,updated_at=now() where balance>0;
update fauxlore.state_profiles sp set treasury=(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=sp.state_id);

create table if not exists fauxlore.state_estate_loans (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  lender text not null check(lender in ('Знать','Духовенство','Горожане','Крестьяне')),
  principal numeric(14,2) not null check(principal>0),
  interest_rate numeric(5,2) not null default 5 check(interest_rate=5),
  due_turn integer not null,
  total_due numeric(14,2) not null check(total_due>0),
  repaid numeric(14,2) not null default 0 check(repaid>=0 and repaid<=total_due),
  late_penalty_applied boolean not null default false,
  created_year integer not null,created_turn integer not null,
  created_by bigint references fauxlore.accounts(id),created_at timestamptz not null default now()
);
create index if not exists state_estate_loans_open_idx on fauxlore.state_estate_loans(state_id,due_turn) where repaid<total_due;
create table if not exists fauxlore.state_estate_loan_events (
  id bigint generated always as identity primary key,
  loan_id bigint not null references fauxlore.state_estate_loans(id) on delete cascade,
  kind text not null check(kind in ('borrow','repay','overdue')),
  amount numeric(14,2) not null default 0,
  year integer not null,turn integer not null,
  actor_id bigint references fauxlore.accounts(id),created_at timestamptz not null default now()
);
alter table fauxlore.state_estate_loans enable row level security;
alter table fauxlore.state_estate_loan_events enable row level security;
revoke all on fauxlore.state_estate_loans,fauxlore.state_estate_loan_events from public,anon,authenticated;

create or replace function fauxlore.charge_army_upkeep_before_turn()
returns trigger language plpgsql security definer set search_path='' as $$
declare report_value jsonb; state_row record; unit_row record; cost numeric; total_cost numeric;
  crown_balance numeric; closing_balance numeric; details jsonb;
begin
  if new.year=old.year and new.turn=old.turn then return new; end if;
  select report into report_value from fauxlore.turn_economy_reports where year=old.year and turn=old.turn for update;
  if report_value is null then raise sqlstate '22023' using message='Не найден налоговый отчёт для расчётного хода'; end if;
  for state_row in select sp.state_id,c.name from fauxlore.state_profiles sp
    join fauxlore.map_categories c on c.layer='states' and c.id=sp.state_id order by sp.state_id loop
    select balance into crown_balance from fauxlore.state_treasuries
      where state_id=state_row.state_id and estate='Корона' for update;
    crown_balance:=coalesce(crown_balance,0);total_cost:=0;details:='[]'::jsonb;
    for unit_row in select u.unit_type_id,t.name,u.quantity,t.upkeep_per_unit
      from fauxlore.state_army_units u join fauxlore.army_unit_types t on t.id=u.unit_type_id
      where u.state_id=state_row.state_id and u.quantity>0 order by u.unit_type_id loop
      cost:=round(unit_row.quantity*unit_row.upkeep_per_unit,2);
      total_cost:=total_cost+cost;
      details:=details||jsonb_build_array(jsonb_build_object('unit_type_id',unit_row.unit_type_id,
        'name',unit_row.name,'quantity',unit_row.quantity,'upkeep_per_unit',unit_row.upkeep_per_unit,'cost',cost));
      insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,unit_type_id,cash_delta,debt_delta,details)
        values(state_row.state_id,'Корона',old.year,old.turn,'army_upkeep',unit_row.unit_type_id,-cost,0,
          jsonb_build_object('cost',cost));
    end loop;
    if total_cost>0 then
      update fauxlore.state_treasuries set balance=balance-total_cost,updated_at=now()
        where state_id=state_row.state_id and estate='Корона';
    end if;
    select coalesce(sum(balance),0) into closing_balance from fauxlore.state_treasuries where state_id=state_row.state_id;
    update fauxlore.state_profiles set treasury=closing_balance where state_id=state_row.state_id;
    select coalesce(jsonb_agg(case when (x.value->>'id')::integer=state_row.state_id then
      x.value||jsonb_build_object('army_upkeep',total_cost,'army_upkeep_paid',total_cost,
        'army_upkeep_arrears',0,'debt_repaid',0,'treasury_debt',0,'closing_treasury',closing_balance,
        'army_details',details,'tax_buckets',coalesce(x.value->'tax_buckets','{}'::jsonb)||
          jsonb_build_object('Корона',crown_balance-total_cost)) else x.value end order by x.ord),'[]'::jsonb)
      into report_value from jsonb_array_elements(report_value) with ordinality x(value,ord);
  end loop;
  update fauxlore.turn_economy_reports set report=report_value where year=old.year and turn=old.turn;
  return new;
end $$;
revoke all on function fauxlore.charge_army_upkeep_before_turn() from public,anon,authenticated;

create or replace function fauxlore.apply_estate_loan_turn_penalties()
returns trigger language plpgsql security definer set search_path='' as $$
declare loan_row record; state_row record;
begin
  if new.turn=old.turn then return new; end if;
  for loan_row in select * from fauxlore.state_estate_loans
    where repaid<total_due and due_turn<=new.turn and not late_penalty_applied for update loop
    perform fauxlore.ensure_state_group_politics(loan_row.state_id);
    update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-.05)
      where state_id=loan_row.state_id and group_type='estate' and group_key=loan_row.lender;
    update fauxlore.state_estate_loans set late_penalty_applied=true where id=loan_row.id;
    insert into fauxlore.state_estate_loan_events(loan_id,kind,year,turn)
      values(loan_row.id,'overdue',new.year,new.turn);
  end loop;
  for state_row in select state_id from fauxlore.state_treasuries
    where estate='Корона' and balance<0 loop
    update fauxlore.state_profiles set prestige=prestige-2 where state_id=state_row.state_id;
  end loop;
  return new;
end $$;
revoke all on function fauxlore.apply_estate_loan_turn_penalties() from public,anon,authenticated;
drop trigger if exists zzz_state_estate_loan_penalties on fauxlore.game_calendar;
create trigger zzz_state_estate_loan_penalties before update of year,turn on fauxlore.game_calendar
for each row execute function fauxlore.apply_estate_loan_turn_penalties();

create or replace function fauxlore.state_estate_loans_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; state_key integer; cal fauxlore.game_calendar;
  lender_value text; amount_value numeric; payment numeric; crown_balance numeric; lender_balance numeric;
  loan_row fauxlore.state_estate_loans; previous fauxlore.operations; fp text; result jsonb;
begin
  actor:=fauxlore.current_account();
  if path !~ '^(my|admin)/states/[0-9]+/loans(/(borrow|[0-9]+/repay))?$' then
    raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if path like 'admin/%' and actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  state_key:=split_part(path,'/',3)::integer;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
    where account_id=actor.id and layer='states' and state_id=state_key) then
    raise sqlstate '42501' using message='Нет прав на государство'; end if;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_key) then
    raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if method='GET' and path~'/loans$' then
    return jsonb_build_object('state_id',state_key,'rate',5,'term_turns',5,
      'crown_balance',(select balance from fauxlore.state_treasuries where state_id=state_key and estate='Корона'),
      'buckets',coalesce((select jsonb_object_agg(estate,balance) from fauxlore.state_treasuries where state_id=state_key),'{}'::jsonb),
      'loans',coalesce((select jsonb_agg(jsonb_build_object('id',id,'lender',lender,'principal',principal,
        'total_due',total_due,'repaid',repaid,'remaining',total_due-repaid,'due_turn',due_turn,
        'overdue',late_penalty_applied) order by id desc) from fauxlore.state_estate_loans
        where state_id=state_key),'[]'::jsonb));
  end if;
  if method<>'POST' or request_id is null or jsonb_typeof(body) is distinct from 'object' or
    body-'amount'-'lender'<>'{}'::jsonb or jsonb_typeof(body->'amount') is distinct from 'number' then
    raise sqlstate '22023' using message='Укажите сумму займа или погашения'; end if;
  amount_value:=(body->>'amount')::numeric;
  if amount_value<=0 or amount_value>=1000000000000 or amount_value<>round(amount_value,2) then
    raise sqlstate '22023' using message='Сумма должна быть положительной, с точностью до 0,01 G'; end if;
  perform pg_advisory_xact_lock(hashtextextended(actor.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=actor.id and o.request_id=state_estate_loans_api.request_id;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  if found then
    if previous.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select * into cal from fauxlore.game_calendar where singleton=true for share;
  if path~'/borrow$' then
    lender_value:=body->>'lender';
    if lender_value is null or lender_value not in ('Знать','Духовенство','Горожане','Крестьяне') then
      raise sqlstate '22023' using message='Выберите сословие-кредитора'; end if;
    select balance into lender_balance from fauxlore.state_treasuries
      where state_id=state_key and estate=lender_value for update;
    if lender_balance is null or lender_balance<amount_value then raise sqlstate '22023' using message='Недостаточно G у сословия'; end if;
    select balance into crown_balance from fauxlore.state_treasuries
      where state_id=state_key and estate='Корона' for update;
    if crown_balance is null then raise sqlstate '22023' using message='Казна Короны не найдена'; end if;
    update fauxlore.state_treasuries set balance=balance-amount_value,updated_at=now()
      where state_id=state_key and estate=lender_value;
    update fauxlore.state_treasuries set balance=balance+amount_value,updated_at=now()
      where state_id=state_key and estate='Корона';
    insert into fauxlore.state_estate_loans(state_id,lender,principal,total_due,due_turn,created_year,created_turn,created_by)
      values(state_key,lender_value,amount_value,round(amount_value*1.05,2),cal.turn+5,cal.year,cal.turn,actor.id)
      returning * into loan_row;
    insert into fauxlore.state_estate_loan_events(loan_id,kind,amount,year,turn,actor_id)
      values(loan_row.id,'borrow',amount_value,cal.year,cal.turn,actor.id);
    result:=jsonb_build_object('id',loan_row.id,'principal',amount_value,'total_due',loan_row.total_due,'due_turn',loan_row.due_turn);
  elsif path~'/[0-9]+/repay$' then
    if body ? 'lender' then raise sqlstate '22023' using message='Кредитор задаётся займом'; end if;
    select * into loan_row from fauxlore.state_estate_loans
      where id=split_part(path,'/',5)::bigint and state_id=state_key for update;
    if not found then raise sqlstate 'P0002' using message='Займ не найден'; end if;
    if amount_value>loan_row.total_due-loan_row.repaid then
      raise sqlstate '22023' using message='Сумма превышает остаток займа'; end if;
    select balance into crown_balance from fauxlore.state_treasuries
      where state_id=state_key and estate='Корона' for update;
    if crown_balance is null or crown_balance<amount_value then raise sqlstate '22023' using message='Недостаточно G у Короны'; end if;
    update fauxlore.state_treasuries set balance=balance-amount_value,updated_at=now()
      where state_id=state_key and estate='Корона';
    update fauxlore.state_treasuries set balance=balance+amount_value,updated_at=now()
      where state_id=state_key and estate=loan_row.lender;
    update fauxlore.state_estate_loans set repaid=repaid+amount_value where id=loan_row.id;
    insert into fauxlore.state_estate_loan_events(loan_id,kind,amount,year,turn,actor_id)
      values(loan_row.id,'repay',amount_value,cal.year,cal.turn,actor.id);
    result:=jsonb_build_object('id',loan_row.id,'paid',amount_value,'remaining',loan_row.total_due-loan_row.repaid-amount_value);
  else raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  update fauxlore.state_profiles set treasury=(select sum(balance) from fauxlore.state_treasuries where state_id=state_key)
    where state_id=state_key;
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(actor.id,state_estate_loans_api.request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.state_estate_loans_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.state_estate_loans_api(text,text,jsonb,uuid) to authenticated;

-- Test turns include loan penalties and their event journal in the snapshot.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure);
  marker:='''game_calendar'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.game_calendar x)';
  if position(marker in fn)=0 then raise exception 'Turn snapshot calendar marker missing'; end if;
  fn:=replace(fn,marker,
    '''state_estate_loans'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.state_estate_loans x),'||chr(10)||
    '    ''state_estate_loan_events'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.state_estate_loan_events x),'||chr(10)||'    '||marker);
  execute fn;
end $$;

create or replace function fauxlore.capture_test_turn_loans()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
    'state_estate_loans',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb) from fauxlore.state_estate_loans x),
    'state_estate_loan_events',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb) from fauxlore.state_estate_loan_events x));
  return new;
end $$;
revoke all on function fauxlore.capture_test_turn_loans() from public,anon,authenticated;
drop trigger if exists turn_test_snapshot_capture_loans on fauxlore.turn_test_snapshot;
create trigger turn_test_snapshot_capture_loans before insert on fauxlore.turn_test_snapshot
for each row execute function fauxlore.capture_test_turn_loans();

create or replace function fauxlore.restore_test_turn_loans()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.after_revision is null or jsonb_typeof(old.payload->'state_estate_loans')<>'array' then return old; end if;
  lock table fauxlore.state_estate_loans,fauxlore.state_estate_loan_events in access exclusive mode;
  delete from fauxlore.state_estate_loan_events where true;
  delete from fauxlore.state_estate_loans where true;
  insert into fauxlore.state_estate_loans overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.state_estate_loans,old.payload->'state_estate_loans');
  insert into fauxlore.state_estate_loan_events overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.state_estate_loan_events,old.payload->'state_estate_loan_events');
  return old;
end $$;
revoke all on function fauxlore.restore_test_turn_loans() from public,anon,authenticated;
drop trigger if exists turn_test_snapshot_restore_loans on fauxlore.turn_test_snapshot;
create trigger turn_test_snapshot_restore_loans before delete on fauxlore.turn_test_snapshot
for each row execute function fauxlore.restore_test_turn_loans();

do $$
declare fn text;
begin
  fn:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
  fn:=replace(fn,'if path ~ ''^(my|admin)/states/[0-9]+/transit-toll$'' then',
    'if path ~ ''^(my|admin)/states/[0-9]+/loans(/(borrow|[0-9]+/repay))?$'' then return fauxlore.state_estate_loans_api(path,method,body,request_id);'||chr(10)||
    '  elsif path ~ ''^(my|admin)/states/[0-9]+/transit-toll$'' then');
  execute fn;
end $$;
notify pgrst,'reload schema';
