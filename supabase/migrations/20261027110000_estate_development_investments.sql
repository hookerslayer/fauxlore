-- Estate-funded development is settled after the regular turn economy. It
-- changes next turn's production and never transfers money through the Crown.
do $$ begin
  if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then
    raise exception 'Rollback the active test turn before adding estate investments';
  end if;
end $$;

create table fauxlore.estate_investment_policies (
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check (estate in ('Знать','Духовенство','Горожане','Крестьяне')),
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (state_id,estate)
);
create table fauxlore.estate_investment_events (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check (estate in ('Знать','Духовенство','Горожане','Крестьяне')),
  province_id integer not null references fauxlore.provinces(id),
  year integer not null,
  turn integer not null,
  cost integer not null check (cost>0),
  development_before integer not null,
  development_after integer not null check (development_after=development_before+1),
  created_at timestamptz not null default now(),
  unique (year,turn,province_id)
);
create index estate_investment_events_state_turn on fauxlore.estate_investment_events(state_id,turn desc,id desc);
alter table fauxlore.estate_investment_policies enable row level security;
alter table fauxlore.estate_investment_events enable row level security;
revoke all on fauxlore.estate_investment_policies,fauxlore.estate_investment_events from public,anon,authenticated;

create or replace function fauxlore.estate_investment_candidate(
  target_state integer,target_estate text,target_year integer,target_turn integer,available_g integer
)
returns table(province_id integer,province_name text,development_before integer,cost integer)
language sql stable security definer set search_path='' as $function$
  select p.id,p.name,p.development,(1000+20*p.development)::integer
  from fauxlore.provinces p
  join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states' and owner.category_id=target_state
  join fauxlore.state_profiles sp on sp.state_id=target_state
  join lateral fauxlore.estate_population(p.province_type,p.population) ep on ep.estate=target_estate
  where p.kind='land' and p.occupation is null and p.development is not null
    and p.development<1000000 and ep.population>0
    and (1000+20*p.development)<=available_g
    and not exists(select 1 from fauxlore.estate_investment_events x
      where x.province_id=p.id and x.year=target_year and x.turn=target_turn)
  order by
    (case
      when target_estate in ('Знать','Крестьяне') and p.province_type='Регион' then 400
      when target_estate='Горожане' and p.province_type in ('Городская','Столичная') then 400
      when target_estate='Духовенство' and p.province_type in ('Городская','Столичная') then 200
      else 0 end)
    +(case
      when target_estate='Знать' and sp.principles->>'structure'='Ленное право' and p.province_type='Регион' then 200
      when target_estate='Знать' and sp.principles->>'economy'='Крепостничество' and p.province_type='Регион' then 200
      when target_estate='Духовенство' and sp.principles->>'authority'='Клир' then 150
      when target_estate='Духовенство' and sp.principles->>'structure'='Командорство' then 100
      when target_estate='Горожане' and sp.principles->>'structure'='Консорциум' and p.province_type in ('Городская','Столичная') then 150
      when target_estate='Горожане' and sp.principles->>'economy'='Гильдии' and p.province_type in ('Городская','Столичная') then 200
      when target_estate='Горожане' and sp.principles->>'economy'='Адмиралтейство' and p.trade_status='Природный порт' then 200
      when target_estate='Крестьяне' and sp.principles->>'structure'='Содружество' and p.province_type='Регион' then 150
      when target_estate='Крестьяне' and sp.principles->>'authority'='Вече' and p.province_type='Регион' then 150
      else 0 end)
    +greatest(0,100-least(p.development,100))*3
    +least(300,floor(ep.population::numeric/50)) desc,
    p.id
  limit 1
$function$;
revoke all on function fauxlore.estate_investment_candidate(integer,text,integer,integer,integer) from public,anon,authenticated;

create or replace function fauxlore.settle_estate_investments()
returns trigger language plpgsql security definer set search_path='' as $function$
declare state_row record; estate_name text; estate_balance numeric; remaining_g integer;
  slots integer; slot integer; picked record; total_cost integer;
begin
  if new.year=old.year and new.turn=old.turn then return new; end if;
  for state_row in select state_id from fauxlore.state_profiles order by state_id loop
    total_cost:=0;
    foreach estate_name in array array['Знать','Духовенство','Горожане','Крестьяне'] loop
      if exists(select 1 from fauxlore.estate_investment_policies policy
        where policy.state_id=state_row.state_id and policy.estate=estate_name and not policy.enabled) then continue; end if;
      select balance into estate_balance from fauxlore.state_treasuries
        where state_id=state_row.state_id and estate=estate_name for update;
      remaining_g:=floor(greatest(coalesce(estate_balance,0),0)*.20)::integer;
      if remaining_g<1000 then continue; end if;
      slots:=case fauxlore.estate_status_for(state_row.state_id,estate_name)
        when 'Ключевое' then 2 else 1 end;
      for slot in 1..slots loop
        select * into picked from fauxlore.estate_investment_candidate(
          state_row.state_id,estate_name,new.year,new.turn,remaining_g);
        exit when not found;
        update fauxlore.state_treasuries set balance=balance-picked.cost,updated_at=now()
          where state_id=state_row.state_id and estate=estate_name and balance>=picked.cost;
        if not found then raise exception 'Estate investment balance changed during turn'; end if;
        update fauxlore.provinces set development=development+1
          where id=picked.province_id and development=picked.development_before;
        if not found then raise exception 'Estate investment province changed during turn'; end if;
        insert into fauxlore.estate_investment_events
          (state_id,estate,province_id,year,turn,cost,development_before,development_after)
          values(state_row.state_id,estate_name,picked.province_id,new.year,new.turn,
            picked.cost,picked.development_before,picked.development_before+1);
        remaining_g:=remaining_g-picked.cost;
        total_cost:=total_cost+picked.cost;
      end loop;
    end loop;
    if total_cost>0 then
      update fauxlore.state_profiles set treasury=(select coalesce(sum(balance),0)
        from fauxlore.state_treasuries where state_id=state_row.state_id) where state_id=state_row.state_id;
      update fauxlore.turn_economy_reports set report=(select jsonb_agg(
        case when (entry.value->>'id')::integer=state_row.state_id then
          entry.value||jsonb_build_object('estate_investments',total_cost,
            'closing_treasury',(select coalesce(sum(balance),0) from fauxlore.state_treasuries where state_id=state_row.state_id),
            'tax_buckets',(select jsonb_object_agg(estate,balance) from fauxlore.state_treasuries where state_id=state_row.state_id))
        else entry.value end order by entry.ord)
        from jsonb_array_elements(report) with ordinality entry(value,ord))
        where year=old.year and turn=old.turn;
    end if;
  end loop;
  return new;
end $function$;
revoke all on function fauxlore.settle_estate_investments() from public,anon,authenticated;
create trigger zzz_estate_investments_after_turn after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.settle_estate_investments();

create or replace function public.estate_investment_api(action text,target_state integer,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; estate_name text; toggled jsonb; calendar_row fauxlore.game_calendar;
begin
  actor:=fauxlore.current_account();
  if target_state is null or not exists(select 1 from fauxlore.state_profiles where state_id=target_state) then
    raise sqlstate '22023' using message='Выберите государство'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states
    where account_id=actor.id and state_id=target_state) then
    raise sqlstate '42501' using message='Нет доступа к государству'; end if;
  if action='save' then
    toggled:=payload->'enabled';
    if jsonb_typeof(toggled) is distinct from 'object' or
      (toggled-array['Знать','Духовенство','Горожане','Крестьяне'])<>'{}'::jsonb or
      (select count(*) from jsonb_object_keys(toggled))<>4 or
      exists(select 1 from jsonb_each(toggled) choice where jsonb_typeof(choice.value)<>'boolean') then
      raise sqlstate '22023' using message='Укажите режим инвестирования для четырёх сословий'; end if;
    foreach estate_name in array array['Знать','Духовенство','Горожане','Крестьяне'] loop
      insert into fauxlore.estate_investment_policies(state_id,estate,enabled)
        values(target_state,estate_name,(toggled->>estate_name)::boolean)
      on conflict(state_id,estate) do update set enabled=excluded.enabled,updated_at=now();
    end loop;
  elsif action<>'snapshot' then
    raise sqlstate '22023' using message='Неизвестное действие вложений';
  end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true;
  return jsonb_build_object('state_id',target_state,'year',calendar_row.year,'turn',calendar_row.turn,
    'estates',(select coalesce(jsonb_agg(jsonb_build_object(
      'name',e.name,'status',fauxlore.estate_status_for(target_state,e.name),
      'balance',coalesce(t.balance,0),'enabled',coalesce(policy.enabled,true),
      'budget',floor(greatest(coalesce(t.balance,0),0)*.20),
      'next_province',(select to_jsonb(candidate) from fauxlore.estate_investment_candidate(
        target_state,e.name,calendar_row.year+1,calendar_row.turn+1,
        floor(greatest(coalesce(t.balance,0),0)*.20)::integer) candidate)
      ) order by e.ord),'[]'::jsonb)
      from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) with ordinality e(name,ord)
      left join fauxlore.state_treasuries t on t.state_id=target_state and t.estate=e.name
      left join fauxlore.estate_investment_policies policy on policy.state_id=target_state and policy.estate=e.name),
    'events',(select coalesce(jsonb_agg(to_jsonb(rows) order by rows.turn desc,rows.id desc),'[]'::jsonb)
      from (select x.id,x.estate,x.province_id,p.name province_name,x.year,x.turn,x.cost,
        x.development_before,x.development_after from fauxlore.estate_investment_events x
        join fauxlore.provinces p on p.id=x.province_id where x.state_id=target_state
        order by x.turn desc,x.id desc limit 20) rows));
end $function$;
revoke all on function public.estate_investment_api(text,integer,jsonb) from public,anon;
grant execute on function public.estate_investment_api(text,integer,jsonb) to authenticated;

-- Extend the safe test-turn rollback with both the province change and journal.
do $$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure);
  marker:='''game_calendar'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.game_calendar x)';
  if position(marker in definition)=0 then raise exception 'Turn snapshot marker missing'; end if;
  definition:=replace(definition,marker,
    '''province_development'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',id,''development'',development) order by id),''[]'') from fauxlore.provinces),'||chr(10)||
    '    ''estate_investment_events'',(select coalesce(jsonb_agg(to_jsonb(x) order by id),''[]'') from fauxlore.estate_investment_events x),'||chr(10)||'    '||marker);
  execute definition;
end $$;

create or replace function fauxlore.capture_test_turn_estate_investments()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
    'province_development',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'development',development) order by id),'[]'::jsonb) from fauxlore.provinces),
    'estate_investment_events',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb) from fauxlore.estate_investment_events x));
  return new;
end $function$;
revoke all on function fauxlore.capture_test_turn_estate_investments() from public,anon,authenticated;
create trigger turn_test_snapshot_capture_estate_investments before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_estate_investments();

create or replace function fauxlore.restore_test_turn_estate_investments()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if old.after_revision is null or jsonb_typeof(old.payload->'province_development')<>'array' then return old; end if;
  lock table fauxlore.provinces,fauxlore.estate_investment_events in access exclusive mode;
  update fauxlore.provinces p set development=(saved->>'development')::integer
    from jsonb_array_elements(old.payload->'province_development') saved where p.id=(saved->>'id')::integer;
  delete from fauxlore.estate_investment_events where true;
  insert into fauxlore.estate_investment_events overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.estate_investment_events,old.payload->'estate_investment_events');
  return old;
end $function$;
revoke all on function fauxlore.restore_test_turn_estate_investments() from public,anon,authenticated;
create trigger turn_test_snapshot_restore_estate_investments before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_estate_investments();
notify pgrst,'reload schema';
