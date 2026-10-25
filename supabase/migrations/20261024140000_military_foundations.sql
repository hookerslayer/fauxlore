-- Military foundations. All game tables remain in the private fauxlore schema.
create table if not exists fauxlore.military_unit_catalog (
 id bigint generated always as identity primary key,
 name text not null unique check(length(btrim(name)) between 2 and 80),
 domain text not null check(domain in ('land','naval','siege')),
 category text not null,
 health integer not null default 10 check(health>0),
 damage numeric not null default 0 check(damage>=0),
 charge_damage numeric check(charge_damage>=0),
 armor numeric not null default 0 check(armor>=0),
 initiative numeric not null default 0,
 power numeric not null default 0 check(power>=0),
 capacity integer not null default 0 check(capacity>=0),
 recruit_cost integer not null check(recruit_cost>0),
 hire_cost numeric(14,2) not null check(hire_cost>=0),
 upkeep numeric(14,2) not null check(upkeep>=0),
 prerequisite text not null default 'none' check(prerequisite in ('none','tumens','saltpeter')),
 state_id integer references fauxlore.state_profiles(state_id) on delete cascade,
 active boolean not null default true
);
create table if not exists fauxlore.military_leaders (
 id bigint generated always as identity primary key,
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 name text not null check(length(btrim(name)) between 2 and 100),
 domain text not null check(domain in ('land','naval')),
 estate text not null check(estate in ('Знать','Духовенство','Горожане','Крестьяне')),
 skills jsonb not null default '{}'::jsonb,
 trait text,
 level integer not null default 1 check(level between 1 and 10),
 xp integer not null default 0 check(xp>=0),
 status text not null default 'active' check(status in ('active','wounded','captured','dead','retired')),
 rolls jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create table if not exists fauxlore.military_traditions (
 state_id integer primary key references fauxlore.state_profiles(state_id) on delete cascade,
 land numeric(5,2) not null default 50 check(land between 0 and 100),
 naval numeric(5,2) not null default 50 check(naval between 0 and 100)
);
create table if not exists fauxlore.military_formations (
 id bigint generated always as identity primary key,
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 name text not null check(length(btrim(name)) between 2 and 100),
 domain text not null check(domain in ('land','naval')),
 kind text not null default 'regular' check(kind in ('regular','mercenary')),
 province_id integer not null references fauxlore.provinces(id),
 leader_id bigint references fauxlore.military_leaders(id) on delete set null,
 mercenary_group_id bigint,
 active boolean not null default true,
 created_at timestamptz not null default now()
);
alter table fauxlore.military_formations add column if not exists free_upkeep_quantity integer not null default 0 check(free_upkeep_quantity>=0);
create table if not exists fauxlore.military_formation_units (
 formation_id bigint not null references fauxlore.military_formations(id) on delete cascade,
 unit_id bigint not null references fauxlore.military_unit_catalog(id),
 quantity integer not null check(quantity>0),
 primary key(formation_id,unit_id)
);
create table if not exists fauxlore.mercenary_groups (
 id bigint generated always as identity primary key,
 name text not null check(length(btrim(name)) between 2 and 100),
 city_province_id integer not null references fauxlore.provinces(id),
 leader_name text not null check(length(btrim(leader_name)) between 2 and 100),
 leader_skills jsonb not null default '{}'::jsonb,
 composition jsonb not null check(jsonb_typeof(composition)='array'),
 price numeric(14,2) not null check(price>=0),
 active boolean not null default true,
 created_at timestamptz not null default now()
);
alter table fauxlore.military_formations add constraint military_formations_mercenary_group_fk
 foreign key(mercenary_group_id) references fauxlore.mercenary_groups(id) on delete set null;
create table if not exists fauxlore.military_wars (
 id bigint generated always as identity primary key,
 attacker_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 defender_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 casus_belli text not null,
 justified boolean not null,
 active boolean not null default true,
 declared_at timestamptz not null default now(),
 ended_at timestamptz,
 peace_terms text,
 check(attacker_id<>defender_id)
);
create unique index if not exists military_one_active_war_pair on fauxlore.military_wars
 (least(attacker_id,defender_id),greatest(attacker_id,defender_id)) where active;
create table if not exists fauxlore.military_diplomacy (
 id bigint generated always as identity primary key,
 kind text not null check(kind in ('war','peace','passage')),
 from_state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 to_state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 war_id bigint references fauxlore.military_wars(id) on delete cascade,
 casus_belli text,
 terms text,
 status text not null default 'pending' check(status in ('pending','awaiting_admin','accepted','rejected','cancelled','ended')),
 justified boolean,
 created_at timestamptz not null default now(),
 decided_at timestamptz,
 check(from_state_id<>to_state_id)
);
create index if not exists military_diplomacy_states_idx on fauxlore.military_diplomacy(from_state_id,to_state_id,status);
create table if not exists fauxlore.military_port_builds (
 id bigint generated always as identity primary key,
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 sea_province_id integer not null references fauxlore.provinces(id),
 marker_id bigint not null references fauxlore.map_markers(id),
 cost numeric(14,2) not null default 10000,
 built_at timestamptz not null default now()
);
do $$ declare t text; begin
 foreach t in array array['military_unit_catalog','military_leaders','military_traditions','military_formations','military_formation_units','mercenary_groups','military_wars','military_diplomacy','military_port_builds'] loop
  execute format('alter table fauxlore.%I enable row level security',t);
  execute format('revoke all on fauxlore.%I from public,anon,authenticated',t);
 end loop;
end $$;
insert into fauxlore.military_unit_catalog(name,domain,category,health,damage,charge_damage,armor,initiative,power,capacity,recruit_cost,hire_cost,upkeep,prerequisite) values
 ('Копейщик','land','Пехота',10,1,null,1,2,2,0,1,10,1,'none'),
 ('Сержант','land','Пехота',10,3,null,3,3,4,0,1,40,4,'none'),
 ('Пикинёр','land','Пехота',10,3,null,4,2,4,0,1,40,4,'none'),
 ('Лучник','land','Пехота',10,2,null,5,6,3,0,1,20,3,'none'),
 ('Арбалетчик','land','Пехота',10,4,null,6,3,4,0,1,60,4,'none'),
 ('Пищальник','land','Пехота',10,8,null,5,4,6,0,1,500,50,'saltpeter'),
 ('Всадник','land','Кавалерия',10,4,6,4,5,8,0,1,120,12,'none'),
 ('Конный сержант','land','Кавалерия',10,6,8,8,4,12,0,1,240,24,'none'),
 ('Конный лучник','land','Кавалерия',10,3,6,6,8,8,0,1,160,12,'tumens'),
 ('Маркитант','land','Логистика',10,0,null,1,0,1,0,1,10,1,'none'),
 ('Когг','naval','Малый флот',100,1,null,1,2,40,50,30,500,50,'none'),
 ('Неф','naval','Большой флот',100,3,null,3,3,220,200,120,2000,200,'none'),
 ('Галера','naval','Малый флот',100,2,null,5,6,200,30,110,1600,160,'none'),
 ('Галеас','naval','Большой флот',100,4,6,4,5,320,120,220,3000,300,'none'),
 ('Требушет','siege','Осада',10,0,null,0,0,24,0,10,1000,40,'none'),
 ('Кулеврина','siege','Артиллерия',10,0,null,0,0,8,0,2,1200,120,'saltpeter'),
 ('Лафетное орудие','siege','Артиллерия',10,0,null,0,0,16,0,8,2400,240,'saltpeter'),
 ('Бомбарда','siege','Артиллерия',10,0,null,0,0,24,0,12,3600,360,'saltpeter')
on conflict(name) do nothing;
insert into fauxlore.military_traditions(state_id)
 select state_id from fauxlore.state_profiles on conflict do nothing;
-- Founding levies are regular formations, with their first 300 spearmen exempt from upkeep.
insert into fauxlore.military_formations(state_id,name,domain,province_id,free_upkeep_quantity)
 select sp.state_id,'Стартовое войско','land',m.province_id,300
 from fauxlore.state_profiles sp join lateral
   (select province_id from fauxlore.map_markers where state_id=sp.state_id and type='capital' order by id limit 1) m on true
 where not exists(select 1 from fauxlore.military_formations f where f.state_id=sp.state_id);
insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
 select f.id,u.id,300 from fauxlore.military_formations f join fauxlore.military_unit_catalog u on u.name='Копейщик'
 where f.name='Стартовое войско' on conflict do nothing;
create or replace function fauxlore.military_initialize_state() returns trigger language plpgsql security definer set search_path='' as $$
declare capital_province integer; formation_key bigint; spearman_key bigint;
begin
 insert into fauxlore.military_traditions(state_id) values(new.state_id) on conflict do nothing;
 select province_id into capital_province from fauxlore.map_markers where state_id=new.state_id and type='capital' order by id limit 1;
 if capital_province is not null then
  insert into fauxlore.military_formations(state_id,name,domain,province_id,free_upkeep_quantity)
   values(new.state_id,'Стартовое войско','land',capital_province,300) returning id into formation_key;
  select id into spearman_key from fauxlore.military_unit_catalog where name='Копейщик';
  insert into fauxlore.military_formation_units values(formation_key,spearman_key,300);
 end if;
 return new;
end $$;
revoke all on function fauxlore.military_initialize_state() from public,anon,authenticated;
create trigger military_initialize_state after insert on fauxlore.state_profiles for each row execute function fauxlore.military_initialize_state();

create or replace function public.military_api(action text, target_state integer default null, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare account_row fauxlore.accounts; sid integer; is_admin boolean; province_key integer; unit_row fauxlore.military_unit_catalog;
 formation_key bigint; group_row fauxlore.mercenary_groups; request_row fauxlore.military_diplomacy;
 amount integer; price numeric; reserve integer; crown numeric; target_id integer; new_id bigint; relation text;
begin
 account_row:=fauxlore.current_account(); is_admin:=account_row.role='admin';
 sid:=coalesce(target_state,(select state_id from fauxlore.account_states where account_id=account_row.id order by state_id limit 1));
 if sid is null and action not in ('catalog','admin_queue') then raise sqlstate '22023' using message='Не выбрано государство'; end if;
 if action not in ('catalog','admin_queue') and not is_admin and not exists
  (select 1 from fauxlore.account_states where account_id=account_row.id and state_id=sid) then
  raise sqlstate '42501' using message='Нет доступа к государству'; end if;
 if action='snapshot' then
  return jsonb_build_object(
   'state_id',sid,'is_admin',is_admin,
   'recruits',(select recruits from fauxlore.state_profiles where state_id=sid),
   'recruitment',fauxlore.state_recruitment(sid),
   'crown',(select balance from fauxlore.state_treasuries where state_id=sid and estate='Корона'),
   'traditions',(select to_jsonb(t)-'state_id' from fauxlore.military_traditions t where state_id=sid),
   'catalog',(select coalesce(jsonb_agg(to_jsonb(u) order by u.domain,u.id),'[]'::jsonb) from fauxlore.military_unit_catalog u where u.active and (u.state_id is null or u.state_id=sid)),
   'formations',(select coalesce(jsonb_agg(to_jsonb(f)||jsonb_build_object('units',
     (select coalesce(jsonb_agg(jsonb_build_object('unit_id',fu.unit_id,'name',u.name,'quantity',fu.quantity,'upkeep',u.upkeep) order by fu.unit_id),'[]'::jsonb)
      from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=f.id)) order by f.id),'[]'::jsonb)
     from fauxlore.military_formations f where f.state_id=sid and f.active),
   'leaders',(select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) from fauxlore.military_leaders l where l.state_id=sid and l.status<>'dead'),
   'mercenaries',(select coalesce(jsonb_agg(to_jsonb(g)||jsonb_build_object('hired_by',
      (select state_id from fauxlore.military_formations f where f.mercenary_group_id=g.id and f.active limit 1)) order by g.id),'[]'::jsonb)
      from fauxlore.mercenary_groups g where g.active),
   'states',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'relation',
      case when c.id=sid then 'own' when exists(select 1 from fauxlore.military_wars w where w.active and
       ((w.attacker_id=sid and w.defender_id=c.id) or (w.defender_id=sid and w.attacker_id=c.id)) and not w.justified and w.attacker_id=sid) then 'unjustified_war'
       when exists(select 1 from fauxlore.military_wars w where w.active and
       ((w.attacker_id=sid and w.defender_id=c.id) or (w.defender_id=sid and w.attacker_id=c.id))) then 'justified_war' else 'peace' end) order by c.name),'[]'::jsonb)
      from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id where c.layer='states'),
   'diplomacy',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at desc),'[]'::jsonb)
     from fauxlore.military_diplomacy d where d.from_state_id=sid or d.to_state_id=sid),
   'provinces',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'kind',p.kind,'type',p.province_type,'owned',pv.category_id=sid,
      'capital',exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='capital'),
      'city',exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='city'),
      'port',exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type='port')) order by p.name),'[]'::jsonb)
      from fauxlore.provinces p left join fauxlore.province_values pv on pv.province_id=p.id and pv.layer='states'
      where pv.category_id=sid or p.kind='sea')
  );
 elsif action='admin_queue' then
  if not is_admin then raise sqlstate '42501' using message='Доступно только администратору'; end if;
  return jsonb_build_object('requests',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb)
   from fauxlore.military_diplomacy d where d.status in ('awaiting_admin')));
 elsif action='hire' then
  amount:=coalesce((payload->>'quantity')::integer,0); province_key:=(payload->>'province_id')::integer;
  if amount<1 or amount>100000 then raise sqlstate '22023' using message='Укажите число юнитов от 1 до 100 000'; end if;
  select * into unit_row from fauxlore.military_unit_catalog where id=(payload->>'unit_id')::bigint and active and (state_id is null or state_id=sid);
  if not found then raise sqlstate '22023' using message='Тип юнита недоступен'; end if;
  if unit_row.domain='naval' then
   if not exists(select 1 from fauxlore.map_markers m where m.province_id=province_key and m.type='port') then
    raise sqlstate '22023' using message='Флот нанимается только в порту'; end if;
  else
   if not exists(select 1 from fauxlore.map_markers m join fauxlore.province_values pv on pv.province_id=m.province_id and pv.layer='states'
      where m.province_id=province_key and m.type in ('city','capital') and pv.category_id=sid) then
    raise sqlstate '22023' using message='Сухопутные и осадные юниты нанимаются в своих городах'; end if;
  end if;
  if unit_row.prerequisite='tumens' and not exists(select 1 from fauxlore.state_profiles where state_id=sid and principles->>'military'='Тумены') then
   raise sqlstate '22023' using message='Нужен принцип «Тумены»'; end if;
  if unit_row.prerequisite='saltpeter' and not exists
    (select 1 from fauxlore.trade_state_resource_turns r where r.state_id=sid and lower(r.resource_name)=lower('Селитра')
      and r.production+r.contract_import+r.zone_import>r.consumption+r.contract_export+r.zone_export
      and (r.year,r.turn)=(select year,turn from fauxlore.game_calendar where singleton)) then
   raise sqlstate '22023' using message='Нужен избыток селитры'; end if;
  select recruits into reserve from fauxlore.state_profiles where state_id=sid for update;
  if reserve<amount*unit_row.recruit_cost then raise sqlstate '22023' using message='Недостаточно рекрутов'; end if;
  price:=amount*unit_row.hire_cost;
  select balance into crown from fauxlore.state_treasuries where state_id=sid and estate='Корона' for update;
  if coalesce(crown,0)<price then raise sqlstate '22023' using message='Недостаточно монет в казне Короны'; end if;
  formation_key:=nullif(payload->>'formation_id','')::bigint;
  if formation_key is not null and not exists(select 1 from fauxlore.military_formations f where f.id=formation_key and f.state_id=sid and f.active
    and f.kind='regular' and f.province_id=province_key and f.domain=case when unit_row.domain='naval' then 'naval' else 'land' end) then
    raise sqlstate '22023' using message='Формирование недоступно для пополнения'; end if;
  if formation_key is null then
   insert into fauxlore.military_formations(state_id,name,domain,province_id)
    values(sid,coalesce(nullif(left(btrim(payload->>'name'),100),''),case when unit_row.domain='naval' then 'Новая флотилия' else 'Новая армия' end),
      case when unit_row.domain='naval' then 'naval' else 'land' end,province_key) returning id into formation_key;
  end if;
  insert into fauxlore.military_formation_units(formation_id,unit_id,quantity) values(formation_key,unit_row.id,amount)
    on conflict(formation_id,unit_id) do update set quantity=fauxlore.military_formation_units.quantity+excluded.quantity;
  update fauxlore.state_profiles set recruits=recruits-amount*unit_row.recruit_cost,treasury=treasury-price where state_id=sid;
  update fauxlore.state_treasuries set balance=balance-price,updated_at=now() where state_id=sid and estate='Корона';
  return jsonb_build_object('formation_id',formation_key,'cost',price,'recruits',amount*unit_row.recruit_cost);
 elsif action='propose' then
  target_id:=(payload->>'to_state_id')::integer;
  if target_id=sid or not exists(select 1 from fauxlore.state_profiles where state_id=target_id) then
   raise sqlstate '22023' using message='Выберите другое государство'; end if;
  if payload->>'kind' not in ('war','peace','passage') then raise sqlstate '22023' using message='Неизвестный договор'; end if;
  if payload->>'kind'='war' then
   if coalesce(length(btrim(payload->>'casus_belli')),0)<2 then raise sqlstate '22023' using message='Выберите Casus Belli'; end if;
   if exists(select 1 from fauxlore.military_wars where active and least(attacker_id,defender_id)=least(sid,target_id)
     and greatest(attacker_id,defender_id)=greatest(sid,target_id)) then raise sqlstate '22023' using message='Война между государствами уже идёт'; end if;
   insert into fauxlore.military_diplomacy(kind,from_state_id,to_state_id,casus_belli,status)
    values('war',sid,target_id,left(payload->>'casus_belli',200),'awaiting_admin') returning id into new_id;
  elsif payload->>'kind'='peace' then
   select id into new_id from fauxlore.military_wars where active and least(attacker_id,defender_id)=least(sid,target_id)
    and greatest(attacker_id,defender_id)=greatest(sid,target_id);
   if new_id is null then raise sqlstate '22023' using message='Между государствами нет войны'; end if;
   if coalesce(length(btrim(payload->>'terms')),0)<2 then raise sqlstate '22023' using message='Укажите условия мира'; end if;
   insert into fauxlore.military_diplomacy(kind,from_state_id,to_state_id,war_id,terms)
    values('peace',sid,target_id,new_id,left(payload->>'terms',10000)) returning id into new_id;
  else
   insert into fauxlore.military_diplomacy(kind,from_state_id,to_state_id,terms)
    values('passage',sid,target_id,left(coalesce(payload->>'terms',''),10000)) returning id into new_id;
  end if;
  insert into fauxlore.notifications(account_id,kind,title,message)
   select a.account_id,'military','Новое дипломатическое действие','Государство отправило договор или объявление войны.'
   from fauxlore.account_states a where a.state_id=target_id;
  if payload->>'kind'='war' then
   insert into fauxlore.notifications(account_id,kind,title,message)
    select id,'military','Война ожидает решения','Проверьте объявление войны в профиле администратора.' from fauxlore.accounts where role='admin';
  end if;
  return jsonb_build_object('id',new_id,'status',case when payload->>'kind'='war' then 'awaiting_admin' else 'pending' end);
 elsif action='decide' then
  select * into request_row from fauxlore.military_diplomacy where id=(payload->>'id')::bigint for update;
  if not found then raise sqlstate '22023' using message='Заявка не найдена'; end if;
  if not is_admin and (request_row.to_state_id<>sid or request_row.status not in ('pending','accepted')) then
   raise sqlstate '42501' using message='Нет доступа к решению'; end if;
  if is_admin and request_row.status not in ('awaiting_admin','accepted') then raise sqlstate '22023' using message='Заявка ещё не готова для судьи'; end if;
  if payload->>'decision'='reject' then
   update fauxlore.military_diplomacy set status='rejected',decided_at=now() where id=request_row.id;
  elsif payload->>'decision'='accept' then
   if request_row.kind='war' then
    if not is_admin then raise sqlstate '42501' using message='Войну подтверждает судья'; end if;
    insert into fauxlore.military_wars(attacker_id,defender_id,casus_belli,justified)
     values(request_row.from_state_id,request_row.to_state_id,request_row.casus_belli,coalesce((payload->>'justified')::boolean,false)) returning id into new_id;
    update fauxlore.military_diplomacy set status='accepted',war_id=new_id,justified=coalesce((payload->>'justified')::boolean,false),decided_at=now() where id=request_row.id;
   elsif request_row.kind='peace' then
    if is_admin then
     update fauxlore.military_wars set active=false,ended_at=now(),peace_terms=request_row.terms where id=request_row.war_id;
     update fauxlore.military_diplomacy set status='accepted',decided_at=now() where id=request_row.id;
    else
     update fauxlore.military_diplomacy set status='awaiting_admin' where id=request_row.id;
    end if;
   else
    update fauxlore.military_diplomacy set status='accepted',decided_at=now() where id=request_row.id;
   end if;
  elsif payload->>'decision'='end' and request_row.kind='passage' and request_row.status='accepted' and
   (is_admin or request_row.from_state_id=sid or request_row.to_state_id=sid) then
   update fauxlore.military_diplomacy set status='ended',decided_at=now() where id=request_row.id;
  else raise sqlstate '22023' using message='Неизвестное решение'; end if;
  insert into fauxlore.notifications(account_id,kind,title,message)
   select a.account_id,'military','Решение по договору','Статус военного дипломатического действия изменён.'
   from fauxlore.account_states a where a.state_id in (request_row.from_state_id,request_row.to_state_id);
  if request_row.kind='peace' and request_row.status='pending' and payload->>'decision'='accept' then
   insert into fauxlore.notifications(account_id,kind,title,message)
    select id,'military','Мир ожидает утверждения','Проверьте условия мира и подтвердите итог вручную.' from fauxlore.accounts where role='admin';
  end if;
  return jsonb_build_object('id',request_row.id,'ok',true);
 end if;
 raise sqlstate '22023' using message='Неизвестная военная операция';
end $$;
revoke all on function public.military_api(text,integer,jsonb) from public,anon;
grant execute on function public.military_api(text,integer,jsonb) to authenticated;
