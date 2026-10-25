-- Colonization missions: isolated from province ownership until completion.
create table if not exists fauxlore.colonization_attempts (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  province_id integer not null references fauxlore.provinces(id) on delete cascade,
  year integer not null,
  turn integer not null,
  sea boolean not null default false,
  roll integer not null check (roll between 0 and 100),
  result integer not null check (result between 0 and 100),
  success boolean not null,
  created_at timestamptz not null default now(),
  unique(state_id,province_id,year,turn)
);
create index if not exists colonization_attempts_turn_idx on fauxlore.colonization_attempts(state_id,year,turn);
alter table fauxlore.colonization_attempts enable row level security;
revoke all on fauxlore.colonization_attempts from public,anon,authenticated;

create table if not exists fauxlore.colonization_missions (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  province_id integer not null references fauxlore.provinces(id) on delete cascade,
  sea boolean not null,
  started_year integer not null,
  started_turn integer not null,
  elapsed_turns smallint not null default 1 check (elapsed_turns between 1 and 4),
  recruits_reserved integer not null check (recruits_reserved >= 0),
  route integer[] not null default '{}',
  fleet_id bigint references fauxlore.military_formations(id) on delete set null,
  roll integer not null,
  final_result integer not null,
  upkeep_paid integer not null default 0,
  status text not null default 'active' check (status in ('active','completed','failed')),
  finished_year integer,
  finished_turn integer,
  created_at timestamptz not null default now()
);
create unique index if not exists colonization_one_active_target on fauxlore.colonization_missions(province_id) where status='active';
create index if not exists colonization_active_state on fauxlore.colonization_missions(state_id) where status='active';
alter table fauxlore.colonization_missions enable row level security;
revoke all on fauxlore.colonization_missions from public,anon,authenticated;

create or replace function fauxlore.colonization_api(action text,target_state integer,payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
  account_row fauxlore.accounts; state_key integer; target_key integer; state_row fauxlore.state_profiles;
  year_value integer; turn_value integer; sea_value boolean; gold_value integer; recruits_value integer;
  gold_base integer; gold_bonus integer; recruit_bonus integer; roll_value integer; final_value integer;
  loss_percent integer; survivors integer; fleet_key bigint; route_ids integer[]; route_json jsonb;
  capacity bigint; first_sea integer; last_sea integer; path_penalty integer:=0; sea_count integer;
  mission_key bigint; crown_balance numeric; p fauxlore.provinces; result_value jsonb; owner_id integer;
begin
  account_row:=fauxlore.current_account();
  state_key:=coalesce(target_state,(select a.state_id from fauxlore.account_states a where a.account_id=account_row.id and a.layer='states' order by a.state_id limit 1));
  if state_key is null then raise sqlstate '22023' using message='Не выбрано государство'; end if;
  if account_row.role<>'admin' and not exists(select 1 from fauxlore.account_states a where a.account_id=account_row.id and a.layer='states' and a.state_id=state_key) then
    raise sqlstate '42501' using message='Нет доступа к государству';
  end if;
  if action='snapshot' then
    return jsonb_build_object(
      'missions',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'state_id',m.state_id,'state_name',c.name,'province_id',m.province_id,'province_name',p.name,'sea',m.sea,'elapsed_turns',m.elapsed_turns,'turns_remaining',4-m.elapsed_turns,'recruits_reserved',m.recruits_reserved,'upkeep_paid',m.upkeep_paid,'route',to_jsonb(m.route),'fleet_id',m.fleet_id,'final_result',m.final_result) order by m.started_year,m.started_turn,m.id)
        from fauxlore.colonization_missions m join fauxlore.provinces p on p.id=m.province_id join fauxlore.map_categories c on c.layer='states' and c.id=m.state_id where m.state_id=state_key and m.status='active'),'[]'::jsonb),
      'attempts_this_turn',(select count(*) from fauxlore.colonization_attempts a cross join fauxlore.game_calendar g where a.state_id=state_key and a.year=g.year and a.turn=g.turn),
      'recruits',(select recruits from fauxlore.state_profiles where state_id=state_key),
      'treasury',(select balance from fauxlore.state_treasuries where state_id=state_key and estate='Корона'));
  end if;
  if action<>'attempt' or jsonb_typeof(payload) is distinct from 'object' then raise sqlstate '22023' using message='Неизвестное действие колонизации'; end if;
  if coalesce(account_row.role,'')<>'admin' and not exists(select 1 from fauxlore.account_states a where a.account_id=account_row.id and a.layer='states' and a.state_id=state_key) then raise sqlstate '42501' using message='Нет доступа к государству'; end if;
  target_key:=(payload->>'province_id')::integer;
  select * into p from fauxlore.provinces where id=target_key and kind='land' for update;
  if not found then raise sqlstate '22023' using message='Выберите сухопутную провинцию'; end if;
  if exists(select 1 from fauxlore.province_values v where v.province_id=target_key and v.layer='states') then raise sqlstate '22023' using message='Колонизировать можно только нейтральную провинцию'; end if;
  if exists(select 1 from fauxlore.colonization_missions m where m.province_id=target_key and m.status='active') then raise sqlstate '22023' using message='Эта провинция уже колонизируется'; end if;
  select year,turn into year_value,turn_value from fauxlore.game_calendar where singleton=true;
  if (select count(*) from fauxlore.colonization_attempts a where a.state_id=state_key and a.year=year_value and a.turn=turn_value)>=2 then raise sqlstate '22023' using message='За ход можно отправить не более двух миссий'; end if;
  if exists(select 1 from fauxlore.colonization_attempts a where a.state_id=state_key and a.province_id=target_key and a.year=year_value and a.turn=turn_value) then raise sqlstate '22023' using message='Эту провинцию уже пытались колонизировать в этом ходу'; end if;
  sea_value:=coalesce((payload->>'sea')::boolean,false); gold_value:=coalesce((payload->>'gold')::integer,0); recruits_value:=coalesce((payload->>'recruits')::integer,0);
  gold_base:=case when sea_value then 2400 else 1200 end;
  if gold_value<gold_base or recruits_value<50 or gold_value>10000000 or recruits_value>1000000 then raise sqlstate '22023' using message=format('Минимум для миссии: %s G и 50 рекрутов',gold_base); end if;
  if not sea_value then
    if not exists(select 1 from fauxlore.map_adjacency a join lateral jsonb_array_elements_text(a.neighbors->target_key::text) n(value) on true join fauxlore.province_values v on v.province_id=n.value::integer and v.layer='states' and v.category_id=state_key join fauxlore.provinces ownp on ownp.id=v.province_id and ownp.kind='land' where a.singleton=true) then raise sqlstate '22023' using message='Сухопутную провинцию можно колонизировать только рядом со своей землёй'; end if;
  else
    fleet_key:=(payload->>'fleet_id')::bigint;
    select coalesce(array_agg((value#>>'{}')::integer),'{}'::integer[]) into route_ids from jsonb_array_elements(coalesce(payload->'route','[]'::jsonb));
    if cardinality(route_ids)<1 or cardinality(route_ids)>40 then raise sqlstate '22023' using message='Маршрут должен содержать от 1 до 40 морских провинций'; end if;
    if not exists(select 1 from fauxlore.military_formations f join fauxlore.military_leaders l on l.id=f.leader_id and l.domain='naval' and l.status<>'dead' where f.id=fleet_key and f.state_id=state_key and f.active and f.domain='naval') then raise sqlstate '22023' using message='Выберите действующую флотилию с адмиралом'; end if;
    if exists(select 1 from fauxlore.colonization_missions m where m.status='active' and m.fleet_id=fleet_key) then raise sqlstate '22023' using message='Эта флотилия уже занята колонизационной миссией'; end if;
    select coalesce(sum(fu.quantity::bigint*u.capacity),0) into capacity from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=fleet_key and u.domain='naval' and u.capacity>0;
    if capacity<recruits_value then raise sqlstate '22023' using message='Вместимость кораблей флотилии меньше числа отправляемых рекрутов'; end if;
    if not exists(select 1 from fauxlore.map_adjacency a join fauxlore.provinces t on t.id=target_key join lateral jsonb_array_elements_text(a.neighbors->target_key::text) n(value) on true join fauxlore.provinces s on s.id=n.value::integer and s.kind='sea' where a.singleton=true and s.id=route_ids[cardinality(route_ids)]) then raise sqlstate '22023' using message='Последняя морская провинция маршрута должна граничить с целью'; end if;
    if not exists(select 1 from fauxlore.map_adjacency a join fauxlore.provinces s on s.id=route_ids[1] and s.kind='sea' join lateral jsonb_array_elements_text(a.neighbors->s.id::text) n(value) on true join fauxlore.province_values v on v.province_id=n.value::integer and v.layer='states' and v.category_id=state_key join fauxlore.provinces land on land.id=v.province_id and land.kind='land' where a.singleton=true) then raise sqlstate '22023' using message='Начальный участок морского маршрута должен вести от собственной суши'; end if;
    for sea_count in 1..cardinality(route_ids) loop
      if not exists(select 1 from fauxlore.provinces where id=route_ids[sea_count] and kind='sea') then raise sqlstate '22023' using message='Маршрут должен проходить только по морским провинциям'; end if;
      if sea_count>1 and not (coalesce((select neighbors->route_ids[sea_count]::text from fauxlore.map_adjacency where singleton),'[]'::jsonb) @> jsonb_build_array(route_ids[sea_count-1])) then raise sqlstate '22023' using message='Морские провинции маршрута должны быть соседними'; end if;
      if exists(select 1 from fauxlore.map_adjacency a join lateral jsonb_array_elements_text(a.neighbors->route_ids[sea_count]::text) n(value) on true join fauxlore.provinces p2 on p2.id=n.value::integer and p2.kind='land' where a.singleton=true) then path_penalty:=path_penalty+2; else path_penalty:=path_penalty+5; end if;
    end loop;
  end if;
  select * into state_row from fauxlore.state_profiles where state_id=state_key for update;
  if state_row.recruits<recruits_value then raise sqlstate '22023' using message='Недостаточно доступных рекрутов'; end if;
  select balance into crown_balance from fauxlore.state_treasuries where state_id=state_key and estate='Корона' for update;
  if coalesce(crown_balance,0)<gold_value then raise sqlstate '22023' using message='Недостаточно средств в казне'; end if;
  roll_value:=floor(random()*101)::integer;
  gold_bonus:=least(15,greatest(0,((gold_value-gold_base)/1000)*5));
  recruit_bonus:=least(15,greatest(0,((recruits_value-50)/100)*5));
  final_value:=greatest(0,least(100,roll_value+gold_bonus+recruit_bonus-path_penalty));
  loss_percent:=case when final_value<10 then 100 when final_value<20 then 50 when final_value<30 then 30 when final_value<40 then 20 when final_value<60 then 15 when final_value<70 then 10 when final_value<90 then 5 else 0 end;
  survivors:=recruits_value-floor(recruits_value*loss_percent/100.0)::integer;
  insert into fauxlore.colonization_attempts(state_id,province_id,year,turn,sea,roll,result,success) values(state_key,target_key,year_value,turn_value,sea_value,roll_value,final_value,final_value>=40);
  update fauxlore.state_profiles set recruits=recruits-recruits_value where state_id=state_key;
  update fauxlore.state_treasuries set balance=balance-gold_value,updated_at=now() where state_id=state_key and estate='Корона';
  update fauxlore.state_profiles sp set treasury=(select coalesce(sum(t.balance),0) from fauxlore.state_treasuries t where t.state_id=state_key) where sp.state_id=state_key;
  if final_value>=40 then
    insert into fauxlore.colonization_missions(state_id,province_id,sea,started_year,started_turn,recruits_reserved,route,fleet_id,roll,final_result)
      values(state_key,target_key,sea_value,year_value,turn_value,survivors,case when sea_value then route_ids else '{}'::integer[] end,case when sea_value then fleet_key else null end,roll_value,final_value) returning id into mission_key;
  else
    update fauxlore.state_profiles set recruits=recruits+survivors where state_id=state_key;
    if sea_value and final_value<10 then
      delete from fauxlore.military_formation_units where formation_id=fleet_key;
      update fauxlore.military_formations set active=false where id=fleet_key;
    end if;
  end if;
  result_value:=jsonb_build_object('id',mission_key,'success',final_value>=40,'roll',roll_value,'result',final_value,'loss_percent',loss_percent,'recruits_lost',recruits_value-survivors,'recruits_returned',case when final_value<40 then survivors else 0 end,'gold_spent',gold_value,'gold_bonus',gold_bonus,'recruit_bonus',recruit_bonus,'route_penalty',path_penalty,'sea',sea_value,'province_id',target_key,'province_name',p.name,'turns',case when final_value>=40 then 4 else 0 end,'catastrophic',sea_value and final_value<10);
  return result_value;
end
$function$;
revoke all on function fauxlore.colonization_api(text,integer,jsonb) from public,anon;
grant execute on function fauxlore.colonization_api(text,integer,jsonb) to authenticated;

create or replace function fauxlore.advance_colonization_missions()
returns trigger language plpgsql security definer set search_path='' as $function$
declare m record; crown_balance numeric; current_year integer; current_turn integer; state_name text;
begin
  if (new.year,new.turn)=(old.year,old.turn) then return new; end if;
  for m in select cm.* from fauxlore.colonization_missions cm where cm.status='active' order by cm.id for update loop
    select balance into crown_balance from fauxlore.state_treasuries where state_id=m.state_id and estate='Корона' for update;
    if coalesce(crown_balance,0)<1000 then
      update fauxlore.colonization_missions set status='failed',finished_year=new.year,finished_turn=new.turn where id=m.id;
      update fauxlore.state_profiles set recruits=recruits+m.recruits_reserved where state_id=m.state_id;
      select name into state_name from fauxlore.map_categories where layer='states' and id=m.state_id;
      insert into fauxlore.notifications(account_id,kind,title,message)
      select recipients.account_id,'colonization_failed','Колонизация сорвана','Миссия в провинции '||(select name from fauxlore.provinces where id=m.province_id)||' прекращена: в казне не хватило 1 000 G на содержание. Провинция снова нейтральна.'
      from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=m.state_id union select ac.id from fauxlore.accounts ac where ac.role='admin') recipients;
      continue;
    end if;
    update fauxlore.state_treasuries set balance=balance-1000,updated_at=now() where state_id=m.state_id and estate='Корона';
    update fauxlore.state_profiles sp set treasury=(select coalesce(sum(t.balance),0) from fauxlore.state_treasuries t where t.state_id=m.state_id) where sp.state_id=m.state_id;
    if m.elapsed_turns>=3 then
      update fauxlore.colonization_missions set status='completed',elapsed_turns=4,upkeep_paid=upkeep_paid+1000,finished_year=new.year,finished_turn=new.turn where id=m.id;
      insert into fauxlore.province_values(province_id,layer,category_id)
        values(m.province_id,'states',m.state_id) on conflict(province_id,layer) do update set category_id=excluded.category_id;
      update fauxlore.provinces p set province_type=case when exists(select 1 from fauxlore.map_markers mk where mk.province_id=p.id and mk.type='capital') then 'Столичная' when exists(select 1 from fauxlore.map_markers mk where mk.province_id=p.id and mk.type='city') then 'Городская' else 'Регион' end where p.id=m.province_id;
      update fauxlore.state_profiles set recruits=recruits+m.recruits_reserved where state_id=m.state_id;
      insert into fauxlore.notifications(account_id,kind,title,message)
      select recipients.account_id,'colonization_completed','Колония основана','Провинция '||(select name from fauxlore.provinces where id=m.province_id)||' теперь принадлежит государству и стала регионом.'
      from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=m.state_id union select ac.id from fauxlore.accounts ac where ac.role='admin') recipients;
    else
      update fauxlore.colonization_missions set elapsed_turns=elapsed_turns+1,upkeep_paid=upkeep_paid+1000 where id=m.id;
    end if;
  end loop;
  return new;
end
$function$;
revoke all on function fauxlore.advance_colonization_missions() from public,anon,authenticated;
drop trigger if exists colonization_advance_on_turn on fauxlore.game_calendar;
create trigger colonization_advance_on_turn after update of year,turn on fauxlore.game_calendar for each row execute function fauxlore.advance_colonization_missions();

-- Add active colonies to the public map and hatch them in the state overlay.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  marker:='''trade_routes'',coalesce((select jsonb_agg(';
  replacement:='''colonies'',coalesce((select jsonb_agg(jsonb_build_object(''province_id'',m.province_id,''state_id'',m.state_id,''state_name'',c.name,''color'',c.color)) from fauxlore.colonization_missions m join fauxlore.map_categories c on c.layer=''states'' and c.id=m.state_id where m.status=''active'' and exists(select 1 from visible p where p.id=m.province_id)),''[]''::jsonb),'||E'\n  '||marker;
  if position(marker in fn)=0 then raise exception 'Could not find map payload trade routes field'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='''occupation_color'',c.color';
  replacement:='''occupation_color'',coalesce(c.color,(select colony_state.color from fauxlore.colonization_missions cm join fauxlore.map_categories colony_state on colony_state.layer=''states'' and colony_state.id=cm.state_id where cm.province_id=p.id and cm.status=''active'' limit 1))';
  if position(marker in fn)=0 then raise exception 'Could not find map occupation color field'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;
