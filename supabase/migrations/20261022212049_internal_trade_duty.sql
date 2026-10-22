create table if not exists fauxlore.state_trade_policies (
  state_id integer primary key references fauxlore.state_profiles(state_id) on delete cascade,
  internal_duty_rate numeric(5,2) not null default 15 check (internal_duty_rate between 0 and 30),
  changed_year integer,
  changed_turn integer,
  changed_by bigint references fauxlore.accounts(id),
  updated_at timestamptz not null default now()
);
insert into fauxlore.state_trade_policies(state_id)
select state_id from fauxlore.state_profiles on conflict do nothing;
alter table fauxlore.state_trade_policies enable row level security;
revoke all on fauxlore.state_trade_policies from public,anon,authenticated;

create or replace function fauxlore.initialize_state_trade_policy()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into fauxlore.state_trade_policies(state_id) values(new.state_id) on conflict(state_id) do nothing;
  return new;
end $$;
revoke all on function fauxlore.initialize_state_trade_policy() from public,anon,authenticated;
drop trigger if exists state_profiles_initialize_trade_policy on fauxlore.state_profiles;
create trigger state_profiles_initialize_trade_policy after insert on fauxlore.state_profiles
for each row execute function fauxlore.initialize_state_trade_policy();

alter table fauxlore.trade_market_settlements
  add column if not exists internal_duty_amount numeric(14,2) not null default 0;

create or replace function fauxlore.apply_internal_trade_duty()
returns trigger language plpgsql security definer set search_path='' as $$
declare base_value numeric; duty_rate numeric;
begin
  select (r->>'value')::numeric into base_value
  from fauxlore.economy_parameters ep
  cross join lateral jsonb_array_elements(ep.config->'resources') r
  where ep.singleton=true and r->>'name'=new.resource_name;
  select internal_duty_rate into duty_rate from fauxlore.state_trade_policies where state_id=new.buyer_state_id;
  new.internal_duty_amount:=round(greatest(new.quantity,0)*coalesce(base_value,0)*coalesce(duty_rate,15)/100,2);
  if new.internal_duty_amount>0 then
    insert into fauxlore.state_treasuries(state_id,estate,balance)
    values(new.buyer_state_id,'Корона',new.internal_duty_amount)
    on conflict(state_id,estate) do update set balance=fauxlore.state_treasuries.balance+excluded.balance,updated_at=now();
  end if;
  return new;
end $$;
revoke all on function fauxlore.apply_internal_trade_duty() from public,anon,authenticated;
drop trigger if exists trade_market_apply_internal_duty on fauxlore.trade_market_settlements;
create trigger trade_market_apply_internal_duty before insert on fauxlore.trade_market_settlements
for each row execute function fauxlore.apply_internal_trade_duty();

create or replace function fauxlore.state_trade_duty_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_key integer; is_admin boolean; cal fauxlore.game_calendar;
  rate_value numeric; policy fauxlore.state_trade_policies; prior fauxlore.operations;
  fp text; result jsonb; state_name text;
begin
  a:=fauxlore.current_account(); is_admin:=a.role='admin';
  if path !~ '^(my|admin)/states/[0-9]+/trade-duty$' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if (path like 'admin/%') is distinct from is_admin then raise sqlstate '42501' using message='Недостаточно прав'; end if;
  state_key:=substring(path from '[0-9]+')::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_key) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if not is_admin and not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_key) then
    raise sqlstate '42501' using message='Это государство не закреплено за вашим аккаунтом'; end if;
  select * into cal from fauxlore.game_calendar where singleton=true;
  select name into state_name from fauxlore.map_categories where layer='states' and id=state_key;
  select * into policy from fauxlore.state_trade_policies where state_id=state_key;
  if method='GET' then
    return jsonb_build_object('state_id',state_key,'state_name',state_name,'rate',coalesce(policy.internal_duty_rate,15),
      'base_rate',15,'minimum',0,'maximum',30,'cost',case when is_admin then 0 else 3 end,
      'changed_this_turn',coalesce(policy.changed_year=cal.year and policy.changed_turn=cal.turn,false),
      'loyalty_change_pp',round((15-coalesce(policy.internal_duty_rate,15))*0.25,2));
  end if;
  if method not in ('POST','PATCH') or request_id is null or jsonb_typeof(body) is distinct from 'object'
    or body-'rate'<>'{}'::jsonb or jsonb_typeof(body->'rate') is distinct from 'number' then
    raise sqlstate '22023' using message='Укажите ставку внутренней пошлины числом от 0 до 30'; end if;
  rate_value:=(body->>'rate')::numeric;
  if rate_value<0 or rate_value>30 then raise sqlstate '22023' using message='Ставка пошлины должна быть от 0 до 30%'; end if;
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into prior from fauxlore.operations o where o.account_id=a.id and o.request_id=state_trade_duty_api.request_id;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  if found then if prior.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return prior.result; end if;
  select * into cal from fauxlore.game_calendar where singleton=true for share;
  select * into policy from fauxlore.state_trade_policies where state_id=state_key for update;
  if policy.internal_duty_rate=rate_value then
    result:=jsonb_build_object('state_id',state_key,'state_name',state_name,'rate',rate_value,'cost',0,'unchanged',true);
  else
    if policy.changed_year=cal.year and policy.changed_turn=cal.turn then raise sqlstate '22023' using message='Ставку пошлины уже меняли в текущем ходу'; end if;
    if not is_admin then
      update fauxlore.state_profiles set prestige=prestige-3 where state_id=state_key and prestige>=3;
      if not found then raise sqlstate '22023' using message='Недостаточно ОП: изменение пошлины стоит 3 ОП'; end if;
    end if;
    update fauxlore.state_trade_policies set internal_duty_rate=rate_value,changed_year=cal.year,changed_turn=cal.turn,changed_by=a.id,updated_at=now() where state_id=state_key;
    result:=jsonb_build_object('state_id',state_key,'state_name',state_name,'rate',rate_value,'cost',case when is_admin then 0 else 3 end,
      'prestige',(select prestige from fauxlore.state_profiles where state_id=state_key));
  end if;
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,state_trade_duty_api.request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.state_trade_duty_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.state_trade_duty_api(text,text,jsonb,uuid) to authenticated;

-- Apply annual urban-loyalty pressure once per completed turn, without changing other estates.
do $$
declare fn text; marker text; addition text; report_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.clear_trade_zones_after_budget()'::regprocedure),chr(13),'');
  marker:='  perform fauxlore.clear_trade_interzone_after_budget(new.year,new.turn);';
  addition:='  update fauxlore.state_group_politics gp set loyalty=greatest(0,least(1,gp.loyalty+(15-coalesce(policy.internal_duty_rate,15))/400)) from fauxlore.state_trade_policies policy where gp.state_id=policy.state_id and gp.group_type=''estate'' and gp.group_key=''Горожане'';'+chr(10)+marker;
  if position('gp.group_key=''Горожане''' in fn)>0 then return; end if;
  if position(marker in fn)=0 then raise exception 'Could not locate interzone settlement call in market turn function'; end if;
  fn:=replace(fn,marker,addition);
  report_fragment:='''market_gold_earned'',market_earned,''market_gold_spent'',market_spent,';
  if position('market_duty_income' in fn)=0 then
    if position(report_fragment in fn)=0 then raise exception 'Could not locate market report income fields'; end if;
    fn:=replace(fn,report_fragment,'''market_gold_earned'',market_earned,''market_gold_spent'',market_spent,''market_duty_income'',(select coalesce(sum(internal_duty_amount),0) from fauxlore.trade_market_settlements where year=new.year and turn=new.turn and buyer_state_id=state_value),');
  end if;
  execute fn;
end $$;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if path ~ '^(my|admin)/states/[0-9]+/trade-duty$' then return fauxlore.state_trade_duty_api(path,method,body,request_id);
  elsif path in ('my/economy/treasuries','admin/economy/treasuries') or path ~ '^(my|admin)/states/[0-9]+/tax-rates$' then
    return fauxlore.state_tax_rates_api(path,method,body,request_id);
  elsif path='admin/turn/test' or path like 'admin/turn/test/%' then return fauxlore.test_turn_api(path,method,body,request_id);
  elsif path='map/revision' and method='GET' then return fauxlore.map_revision();
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
  elsif path='admin/turn/latest-report' then return fauxlore.turn_budget_report_api(path,method);
  elsif path='game/calendar' or path='admin/turn/advance' then return fauxlore.turn_api(path,method,body,request_id);
  elsif path='admin/states' then return fauxlore.state_api(path,method,body,request_id);
  elsif path='my/states' or path like 'admin/states/%' then return fauxlore.game_state_api(path,method,body,request_id);
  else return fauxlore.api(path,method,body,request_id); end if;
end $$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
