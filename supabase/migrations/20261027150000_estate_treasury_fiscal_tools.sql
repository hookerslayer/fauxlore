-- Voluntary Crown-to-estate investment and wartime estate levies.
do $$ begin
 if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
   raise exception 'Rollback the active test turn before adding estate fiscal tools'; end if;
end $$;

create table fauxlore.estate_fiscal_events (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check (estate in ('Знать','Духовенство','Горожане','Крестьяне')),
  kind text not null check (kind in ('loyalty_investment','military_tax')),
  war_id bigint references fauxlore.military_wars(id) on delete set null,
  year integer not null,
  turn integer not null,
  amount numeric(14,2) not null check (amount>0),
  loyalty_change numeric(7,4) not null,
  expires_year integer,
  recovery_remaining numeric(7,4) not null default 0 check (recovery_remaining>=0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check ((kind='loyalty_investment' and war_id is null and expires_year is not null and loyalty_change>0)
      or (kind='military_tax' and war_id is not null and expires_year is null and loyalty_change<0))
);
create unique index estate_military_tax_once_per_war on fauxlore.estate_fiscal_events(state_id,war_id,estate)
  where kind='military_tax';
create index estate_fiscal_history on fauxlore.estate_fiscal_events(state_id,id desc);
alter table fauxlore.estate_fiscal_events enable row level security;
revoke all on fauxlore.estate_fiscal_events from public,anon,authenticated;

create or replace function public.estate_fiscal_api(action text,target_state integer,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; cal fauxlore.game_calendar; war fauxlore.military_wars;
  estate_name text; amount_value numeric; loyalty_value numeric; bonus_value numeric;
  maximum_value numeric; crown_balance numeric; estate_balance numeric; tax_value numeric;
  opponent_id integer; result jsonb;
begin
 actor:=fauxlore.current_account();
 if target_state is null or not exists(select 1 from fauxlore.state_profiles where state_id=target_state) then
   raise sqlstate '22023' using message='Выберите государство'; end if;
 if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
   where account_id=actor.id and state_id=target_state) then
   raise sqlstate '42501' using message='Нет доступа к государству'; end if;
 if action not in ('snapshot','invest','military_tax') then
   raise sqlstate '22023' using message='Неизвестная операция с казной сословий'; end if;
 if action='snapshot' then
   return jsonb_build_object(
     'state_id',target_state,
     'crown_balance',(select balance from fauxlore.state_treasuries where state_id=target_state and estate='Корона'),
     'estates',(select coalesce(jsonb_agg(jsonb_build_object('name',e.name,'balance',coalesce(t.balance,0),
       'loyalty',coalesce(g.loyalty,.5),'investment_bonus',coalesce((select sum(x.loyalty_change)
         from fauxlore.estate_fiscal_events x where x.state_id=target_state and x.estate=e.name
          and x.kind='loyalty_investment' and x.active),0),
       'investment_expires_year',(select min(x.expires_year) from fauxlore.estate_fiscal_events x
         where x.state_id=target_state and x.estate=e.name and x.kind='loyalty_investment' and x.active),
       'tax_recovery',(select coalesce(sum(x.recovery_remaining),0) from fauxlore.estate_fiscal_events x
         where x.state_id=target_state and x.estate=e.name and x.kind='military_tax' and x.active)
       ) order by e.ord),'[]'::jsonb) from
       unnest(array['Знать','Духовенство','Горожане','Крестьяне']) with ordinality e(name,ord)
       left join fauxlore.state_treasuries t on t.state_id=target_state and t.estate=e.name
       left join fauxlore.state_group_politics g on g.state_id=target_state and g.group_type='estate' and g.group_key=e.name),
     'wars',(select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'opponent_id',
       case when w.attacker_id=target_state then w.defender_id else w.attacker_id end,
       'attacker_id',w.attacker_id,'defender_id',w.defender_id,'casus_belli',w.casus_belli,
       'used_estates',(select coalesce(jsonb_agg(x.estate order by x.estate),'[]'::jsonb)
         from fauxlore.estate_fiscal_events x where x.state_id=target_state and x.war_id=w.id and x.kind='military_tax'))
       order by w.declared_at),'[]'::jsonb) from fauxlore.military_wars w
       where w.active and target_state in (w.attacker_id,w.defender_id)),
     'events',(select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'estate',x.estate,'kind',x.kind,
       'war_id',x.war_id,'year',x.year,'turn',x.turn,'amount',x.amount,'loyalty_change',x.loyalty_change,
       'expires_year',x.expires_year,'recovery_remaining',x.recovery_remaining,'active',x.active)
       order by x.id desc),'[]'::jsonb) from (select * from fauxlore.estate_fiscal_events
       where state_id=target_state order by id desc limit 40) x),
     'year',(select year from fauxlore.game_calendar where singleton),
     'turn',(select turn from fauxlore.game_calendar where singleton));
 end if;
 estate_name:=payload->>'estate';
 if estate_name is null or estate_name not in ('Знать','Духовенство','Горожане','Крестьяне') then
   raise sqlstate '22023' using message='Выберите сословие'; end if;
 select * into cal from fauxlore.game_calendar where singleton for share;
 perform 1 from fauxlore.state_profiles where state_id=target_state for update;
 perform fauxlore.ensure_state_group_politics(target_state);
 select loyalty into loyalty_value from fauxlore.state_group_politics
   where state_id=target_state and group_type='estate' and group_key=estate_name for update;
 select balance into crown_balance from fauxlore.state_treasuries
   where state_id=target_state and estate='Корона' for update;
 if crown_balance is null then raise sqlstate '22023' using message='Казна Короны не найдена'; end if;
 select balance into estate_balance from fauxlore.state_treasuries
   where state_id=target_state and estate=estate_name for update;
 if estate_balance is null then raise sqlstate '22023' using message='Казна сословия не найдена'; end if;
 if action='invest' then
   if jsonb_typeof(payload->'amount') is distinct from 'number' then
     raise sqlstate '22023' using message='Укажите сумму вложения'; end if;
   amount_value:=(payload->>'amount')::numeric;
   if amount_value<1000 or amount_value>=1000000000000 or amount_value<>trunc(amount_value)
      or mod(amount_value,1000)<>0 then
     raise sqlstate '22023' using message='Сумма должна быть целым числом не меньше 1 000 G и кратна 1 000'; end if;
   if crown_balance<amount_value then raise sqlstate '22023' using message='Недостаточно G в Казне Короны'; end if;
   bonus_value:=(amount_value/1000)*case when estate_name in ('Горожане','Крестьяне') then .01 else .005 end;
   if loyalty_value+bonus_value>1 then
     maximum_value:=floor((1-loyalty_value)/case when estate_name in ('Горожане','Крестьяне') then .01 else .005 end)*1000;
     raise sqlstate '22023' using message=format('Вложение превышает предел лояльности. Максимум сейчас: %s G',maximum_value); end if;
   update fauxlore.state_treasuries set balance=balance-amount_value,updated_at=now()
     where state_id=target_state and estate='Корона';
   update fauxlore.state_treasuries set balance=balance+amount_value,updated_at=now()
     where state_id=target_state and estate=estate_name;
   update fauxlore.state_group_politics set loyalty=loyalty+bonus_value
     where state_id=target_state and group_type='estate' and group_key=estate_name;
   insert into fauxlore.estate_fiscal_events(state_id,estate,kind,year,turn,amount,loyalty_change,expires_year)
     values(target_state,estate_name,'loyalty_investment',cal.year,cal.turn,amount_value,bonus_value,cal.year+5);
   insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
     values(target_state,'Корона',cal.year,cal.turn,'estate_loyalty_investment',-amount_value,0,
       jsonb_build_object('estate',estate_name,'amount',amount_value)),
       (target_state,estate_name,cal.year,cal.turn,'estate_loyalty_investment',amount_value,0,
       jsonb_build_object('direction','received','loyalty_bonus',bonus_value));
   result:=jsonb_build_object('estate',estate_name,'amount',amount_value,
     'loyalty_bonus',bonus_value,'expires_year',cal.year+5);
 else
   if jsonb_typeof(payload->'war_id') is distinct from 'number' then
     raise sqlstate '22023' using message='Выберите активную войну'; end if;
   select * into war from fauxlore.military_wars where id=(payload->>'war_id')::bigint
     and active and target_state in (attacker_id,defender_id) for share;
   if not found then raise sqlstate '22023' using message='Военный налог доступен только во время активной войны'; end if;
   if exists(select 1 from fauxlore.estate_fiscal_events where state_id=target_state
     and war_id=war.id and estate=estate_name and kind='military_tax') then
     raise sqlstate '22023' using message='Это сословие уже обложено военным налогом в этой войне'; end if;
   if estate_balance<=0 then raise sqlstate '22023' using message='В казне сословия нет средств для военного налога'; end if;
   tax_value:=round(estate_balance*.5,2);
   bonus_value:=least(.20,loyalty_value);
   update fauxlore.state_treasuries set balance=balance-tax_value,updated_at=now()
     where state_id=target_state and estate=estate_name;
   update fauxlore.state_treasuries set balance=balance+tax_value,updated_at=now()
     where state_id=target_state and estate='Корона';
   update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-bonus_value)
     where state_id=target_state and group_type='estate' and group_key=estate_name;
   insert into fauxlore.estate_fiscal_events(state_id,estate,kind,war_id,year,turn,amount,
     loyalty_change,recovery_remaining,active)
     values(target_state,estate_name,'military_tax',war.id,cal.year,cal.turn,tax_value,-bonus_value,bonus_value,bonus_value>0);
   insert into fauxlore.state_budget_ledger(state_id,estate,year,turn,kind,cash_delta,debt_delta,details)
     values(target_state,estate_name,cal.year,cal.turn,'estate_military_tax',-tax_value,0,
       jsonb_build_object('war_id',war.id)),
       (target_state,'Корона',cal.year,cal.turn,'estate_military_tax',tax_value,0,
       jsonb_build_object('estate',estate_name,'war_id',war.id));
   result:=jsonb_build_object('estate',estate_name,'war_id',war.id,
     'amount',tax_value,'loyalty_loss',bonus_value,'recovery_per_turn',case when bonus_value>0 then .01 else 0 end);
 end if;
 update fauxlore.state_profiles set treasury=(select coalesce(sum(balance),0)
   from fauxlore.state_treasuries where state_id=target_state) where state_id=target_state;
 return result;
end $function$;
revoke all on function public.estate_fiscal_api(text,integer,jsonb) from public,anon;
grant execute on function public.estate_fiscal_api(text,integer,jsonb) to authenticated;

create or replace function fauxlore.advance_estate_fiscal_events()
returns trigger language plpgsql security definer set search_path='' as $function$
declare event_row fauxlore.estate_fiscal_events; restored numeric;
begin
 if new.year=old.year and new.turn=old.turn then return new; end if;
 for event_row in select * from fauxlore.estate_fiscal_events where active order by id for update loop
   if event_row.kind='loyalty_investment' and new.year>=event_row.expires_year then
     update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-event_row.loyalty_change)
       where state_id=event_row.state_id and group_type='estate' and group_key=event_row.estate;
     update fauxlore.estate_fiscal_events set active=false where id=event_row.id;
   elsif event_row.kind='military_tax' then
     restored:=least(.01,event_row.recovery_remaining);
     update fauxlore.state_group_politics set loyalty=least(1,loyalty+restored)
       where state_id=event_row.state_id and group_type='estate' and group_key=event_row.estate;
     update fauxlore.estate_fiscal_events set recovery_remaining=recovery_remaining-restored,
       active=(recovery_remaining-restored)>0 where id=event_row.id;
   end if;
 end loop;
 return new;
end $function$;
revoke all on function fauxlore.advance_estate_fiscal_events() from public,anon,authenticated;
create trigger zzzzz_estate_fiscal_events after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.advance_estate_fiscal_events();

-- Include balances and temporary loyalty effects in the reversible admin test turn.
create or replace function fauxlore.capture_test_turn_estate_fiscal()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
   'estate_fiscal_events',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)
     from fauxlore.estate_fiscal_events x));
 return new;
end $function$;
revoke all on function fauxlore.capture_test_turn_estate_fiscal() from public,anon,authenticated;
create trigger turn_test_snapshot_capture_estate_fiscal before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_estate_fiscal();

create or replace function fauxlore.restore_test_turn_estate_fiscal()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
 if old.after_revision is null or jsonb_typeof(old.payload->'estate_fiscal_events')<>'array' then return old; end if;
 lock table fauxlore.estate_fiscal_events in access exclusive mode;
 delete from fauxlore.estate_fiscal_events where true;
 insert into fauxlore.estate_fiscal_events overriding system value
   select * from jsonb_populate_recordset(null::fauxlore.estate_fiscal_events,
     old.payload->'estate_fiscal_events');
 return old;
end $function$;
revoke all on function fauxlore.restore_test_turn_estate_fiscal() from public,anon,authenticated;
create trigger turn_test_snapshot_restore_estate_fiscal before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_estate_fiscal();
notify pgrst,'reload schema';
