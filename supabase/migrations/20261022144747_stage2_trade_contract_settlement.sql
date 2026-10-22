-- Trade phase 2: recurring direct-contract deliveries and payments are settled
-- atomically with a turn, with neutral-route loss and a per-turn ledger.

create table if not exists fauxlore.trade_settlements (
  agreement_id bigint not null references fauxlore.trade_agreements(id) on delete cascade,
  year integer not null,
  turn integer not null,
  direction text not null check(direction in ('forward','reverse')),
  item_kind text not null check(item_kind in ('resource','gold')),
  item_name text not null,
  requested numeric(14,2) not null check(requested>=0),
  sent numeric(14,2) not null check(sent>=0),
  received numeric(14,2) not null check(received>=0),
  lost numeric(14,2) not null check(lost>=0),
  settled_at timestamptz not null default now(),
  primary key(agreement_id,year,turn,direction,item_kind,item_name),
  check(sent<=requested),
  check(received<=sent),
  check(lost=sent-received)
);
alter table fauxlore.trade_settlements enable row level security;
revoke all on fauxlore.trade_settlements from public,anon,authenticated;
create index if not exists trade_settlements_year_turn_idx on fauxlore.trade_settlements(year desc,turn desc);
create index if not exists trade_settlements_agreement_idx on fauxlore.trade_settlements(agreement_id,year desc,turn desc);

drop trigger if exists trade_agreements_live_revision on fauxlore.trade_agreements;
create trigger trade_agreements_live_revision after insert or update or delete on fauxlore.trade_agreements
for each statement execute function fauxlore.bump_live_revision();
drop trigger if exists trade_settlements_live_revision on fauxlore.trade_settlements;
create trigger trade_settlements_live_revision after insert or update or delete on fauxlore.trade_settlements
for each statement execute function fauxlore.bump_live_revision();

create or replace function fauxlore.settle_trade_contracts_after_budget()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  agreement fauxlore.trade_agreements; term jsonb; item jsonb; direction_value text; source_state integer; target_state integer;
  goods jsonb; requested numeric(14,2); sent numeric(14,2); received numeric(14,2); lost numeric(14,2);
  available numeric(14,2); balance_value numeric(14,2); neutral_count integer; passage integer; state_value integer;
  report_value jsonb; report_item jsonb; state_name text; treasury_total numeric(14,2);
  gold_sent numeric(14,2); gold_received numeric(14,2); resources_sent numeric(14,2); resources_received numeric(14,2);
  gold_loss numeric(14,2); resource_loss numeric(14,2);
begin
  create temporary table if not exists pg_temp.trade_turn_stock(
    state_id integer not null,resource_name text not null,available numeric(14,2) not null,
    primary key(state_id,resource_name)
  ) on commit drop;
  truncate pg_temp.trade_turn_stock;

  for agreement in
    select ta.* from fauxlore.trade_agreements ta
    where ta.status='accepted' and (ta.accepted_year,new.turn) is not null
      and (ta.accepted_year<new.year or (ta.accepted_year=new.year and ta.accepted_turn<new.turn))
    order by ta.created_at,ta.id for update
  loop
    select count(*) into neutral_count
    from unnest(agreement.route_province_ids[2:array_length(agreement.route_province_ids,1)-1]) route(province_id)
    where not exists(select 1 from fauxlore.province_values v where v.province_id=route.province_id and v.layer='states')
      and not exists(select 1 from fauxlore.provinces p where p.id=route.province_id and p.occupation is not null);

    for passage in 1..2 loop
      if passage=1 then source_state:=agreement.from_state_id;target_state:=agreement.to_state_id;direction_value:='forward';goods:=agreement.terms->'from_goods';
      else source_state:=agreement.to_state_id;target_state:=agreement.from_state_id;direction_value:='reverse';goods:=agreement.terms->'to_goods';end if;
      for item in select value from jsonb_array_elements(coalesce(goods,'[]'::jsonb)) e(value) order by value->>'name' loop
        requested:=(item->>'quantity')::numeric;
        select available into available from pg_temp.trade_turn_stock where state_id=source_state and resource_name=item->>'name' for update;
        if not found then
          available:=greatest(0,fauxlore.trade_resource_surplus(source_state,item->>'name'));
          insert into pg_temp.trade_turn_stock(state_id,resource_name,available) values(source_state,item->>'name',available);
        end if;
        sent:=least(requested,available);received:=sent;
        if sent>0 then for state_value in 1..neutral_count loop received:=round(received*.95,2);end loop; end if;
        lost:=sent-received;
        update pg_temp.trade_turn_stock set available=available-sent where state_id=source_state and resource_name=item->>'name';
        insert into pg_temp.trade_turn_stock(state_id,resource_name,available) values(target_state,item->>'name',received)
          on conflict(state_id,resource_name) do update set available=pg_temp.trade_turn_stock.available+excluded.available;
        insert into fauxlore.trade_settlements(agreement_id,year,turn,direction,item_kind,item_name,requested,sent,received,lost)
          values(agreement.id,new.year,new.turn,direction_value,'resource',item->>'name',requested,sent,received,lost);
      end loop;
    end loop;

    for passage in 1..2 loop
      if passage=1 then source_state:=agreement.from_state_id;target_state:=agreement.to_state_id;direction_value:='forward';requested:=coalesce((agreement.terms->>'from_gold')::numeric,0);
      else source_state:=agreement.to_state_id;target_state:=agreement.from_state_id;direction_value:='reverse';requested:=coalesce((agreement.terms->>'to_gold')::numeric,0);end if;
      if requested>0 then
        insert into fauxlore.state_treasuries(state_id,estate,balance) values(source_state,'Корона',0) on conflict(state_id,estate) do nothing;
        insert into fauxlore.state_treasuries(state_id,estate,balance) values(target_state,'Корона',0) on conflict(state_id,estate) do nothing;
        select balance into balance_value from fauxlore.state_treasuries where state_id=source_state and estate='Корона' for update;
        sent:=least(requested,balance_value);received:=sent;
        if sent>0 then for state_value in 1..neutral_count loop received:=round(received*.95,2);end loop; end if;
        lost:=sent-received;
        if sent>0 then
          update fauxlore.state_treasuries set balance=balance-sent,updated_at=now() where state_id=source_state and estate='Корона';
          update fauxlore.state_treasuries set balance=balance+received,updated_at=now() where state_id=target_state and estate='Корона';
        end if;
        insert into fauxlore.trade_settlements(agreement_id,year,turn,direction,item_kind,item_name,requested,sent,received,lost)
          values(agreement.id,new.year,new.turn,direction_value,'gold','G',requested,sent,received,lost);
      end if;
    end loop;
  end loop;

  update fauxlore.state_profiles sp set treasury=(select coalesce(sum(st.balance),0) from fauxlore.state_treasuries st where st.state_id=sp.state_id)
    where exists(select 1 from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id
      where ts.year=new.year and ts.turn=new.turn and sp.state_id in(ta.from_state_id,ta.to_state_id));

  select report into report_value from fauxlore.turn_economy_reports where year=new.year and turn=new.turn for update;
  for state_value in
    select distinct state_id from (
      select ta.from_state_id state_id from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id where ts.year=new.year and ts.turn=new.turn
      union select ta.to_state_id from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id where ts.year=new.year and ts.turn=new.turn
    ) parties order by state_id
  loop
    select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=state_value;
    select coalesce(sum(st.balance),0) into treasury_total from fauxlore.state_treasuries st where st.state_id=state_value;
    select coalesce(sum(case when ts.item_kind='gold' and sender.state_id=state_value then ts.sent else 0 end),0),
      coalesce(sum(case when ts.item_kind='gold' and receiver.state_id=state_value then ts.received else 0 end),0),
      coalesce(sum(case when ts.item_kind='resource' and sender.state_id=state_value then ts.sent else 0 end),0),
      coalesce(sum(case when ts.item_kind='resource' and receiver.state_id=state_value then ts.received else 0 end),0),
      coalesce(sum(case when ts.item_kind='gold' then ts.lost else 0 end),0),
      coalesce(sum(case when ts.item_kind='resource' then ts.lost else 0 end),0)
      into gold_sent,gold_received,resources_sent,resources_received,gold_loss,resource_loss
    from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id
    cross join lateral (select case when ts.direction='forward' then ta.from_state_id else ta.to_state_id end state_id) sender
    cross join lateral (select case when ts.direction='forward' then ta.to_state_id else ta.from_state_id end state_id) receiver
    where ts.year=new.year and ts.turn=new.turn and state_value in(ta.from_state_id,ta.to_state_id);
    if exists(select 1 from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) entry(value) where (value->>'id')::integer=state_value) then
      select coalesce(jsonb_agg(case when (value->>'id')::integer=state_value then value||jsonb_build_object(
        'trade_gold_sent',gold_sent,'trade_gold_received',gold_received,'trade_resource_units_sent',resources_sent,
        'trade_resource_units_received',resources_received,'trade_gold_losses',gold_loss,'trade_resource_losses',resource_loss,
        'closing_treasury',treasury_total,'tax_buckets',coalesce(value->'tax_buckets','{}'::jsonb)||jsonb_build_object('Корона',
          coalesce((select balance from fauxlore.state_treasuries where state_id=state_value and estate='Корона'),0))) else value end order by ord),'[]'::jsonb)
        into report_value from jsonb_array_elements(report_value) with ordinality rows(value,ord);
    else
      report_value:=coalesce(report_value,'[]'::jsonb)||jsonb_build_array(jsonb_build_object('id',state_value,'name',state_name,'province_count',0,
        'gross_taxes',0,'crown_taxes',0,'estate_taxes',0,'tax_buckets',jsonb_build_object('Корона',
          coalesce((select balance from fauxlore.state_treasuries where state_id=state_value and estate='Корона'),0)),
        'tax_details','[]'::jsonb,'trade_gold_sent',gold_sent,'trade_gold_received',gold_received,
        'trade_resource_units_sent',resources_sent,'trade_resource_units_received',resources_received,
        'trade_gold_losses',gold_loss,'trade_resource_losses',resource_loss,'closing_treasury',treasury_total));
    end if;
  end loop;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb) where year=new.year and turn=new.turn;
  return null;
end $$;
revoke all on function fauxlore.settle_trade_contracts_after_budget() from public,anon,authenticated;
drop trigger if exists game_calendar_settle_trade_contracts on fauxlore.turn_economy_reports;
create trigger game_calendar_settle_trade_contracts after insert on fauxlore.turn_economy_reports
for each row execute function fauxlore.settle_trade_contracts_after_budget();

-- Keep test-turn rollback complete for settlement rows, and block rollback if a
-- new agreement/settlement changes after the test turn.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.test_turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:='''state_budget_ledger'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.state_budget_ledger x),';
  new_fragment:=old_fragment||'''trade_settlements'',(select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from fauxlore.trade_settlements x),';
  if position('trade_settlements' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn snapshot ledger'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='fauxlore.state_budget_ledger,fauxlore.turn_economy_reports,fauxlore.game_calendar in access exclusive mode';
    new_fragment:='fauxlore.state_budget_ledger,fauxlore.trade_settlements,fauxlore.turn_economy_reports,fauxlore.game_calendar in access exclusive mode';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn rollback locks'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='delete from fauxlore.state_budget_ledger where true;';
    new_fragment:='delete from fauxlore.state_budget_ledger where true; delete from fauxlore.trade_settlements where true;';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn settlement cleanup'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    old_fragment:='''state_treasury_debts'',''state_budget_ledger'',''turn_economy_reports''';
    new_fragment:='''state_treasury_debts'',''state_budget_ledger'',''trade_settlements'',''turn_economy_reports''';
    if position(old_fragment in fn)=0 then raise exception 'Could not locate test-turn settlement restore list'; end if;
    fn:=replace(fn,old_fragment,new_fragment);
    execute fn;
  end if;
end $$;

-- Add the current turn's settlement journal to the same private RPC response
-- used by the trade menu.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.trade_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$if path='my/trade-agreements' and method='GET' and body='{}'::jsonb then$old$;
  new_fragment:=$new$if path='my/trade-settlements' and method='GET' and body='{}'::jsonb then
    return jsonb_build_object('lines',coalesce((select jsonb_agg(jsonb_build_object('agreement_id',ts.agreement_id,'year',ts.year,'turn',ts.turn,
      'direction',ts.direction,'item_kind',ts.item_kind,'item_name',ts.item_name,'sender',sender.name,'recipient',recipient.name,
      'requested',ts.requested,'sent',ts.sent,'received',ts.received,'lost',ts.lost) order by ts.year desc,ts.turn desc,ts.agreement_id desc,ts.direction,ts.item_kind,ts.item_name)
      from fauxlore.trade_settlements ts join fauxlore.trade_agreements ta on ta.id=ts.agreement_id
      join fauxlore.map_categories sender on sender.layer='states' and sender.id=case when ts.direction='forward' then ta.from_state_id else ta.to_state_id end
      join fauxlore.map_categories recipient on recipient.layer='states' and recipient.id=case when ts.direction='forward' then ta.to_state_id else ta.from_state_id end
      where actor.role='admin' or exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id in(ta.from_state_id,ta.to_state_id))),'[]'::jsonb));
  end if;
  if path='my/trade-agreements' and method='GET' and body='{}'::jsonb then$new$;
  if position('my/trade-settlements' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate trade agreement list route'; end if;
    execute replace(fn,old_fragment,new_fragment);
  end if;
end $$;

do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  old_fragment:=$old$elsif path='my/trade-agreements' or path ~ '^(my|admin)/trade-agreements/[0-9]+/(accept|decline|cancel)$' then return fauxlore.trade_api(path,method,body,request_id);$old$;
  new_fragment:=$new$elsif path in ('my/trade-agreements','my/trade-settlements') or path ~ '^(my|admin)/trade-agreements/[0-9]+/(accept|decline|cancel)$' then return fauxlore.trade_api(path,method,body,request_id);$new$;
  if position('my/trade-settlements' in fn)=0 then
    if position(old_fragment in fn)=0 then raise exception 'Could not locate trade RPC dispatch'; end if;
    execute replace(fn,old_fragment,new_fragment);
  end if;
end $$;

-- Include settlement rows in the administrator's reversible test-turn snapshot.
