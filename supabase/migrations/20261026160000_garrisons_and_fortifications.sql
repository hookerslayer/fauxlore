-- Province garrisons and fortifications. Levels: fort 1=fort, 2..4=fortress I..III.
create table fauxlore.garrison_sites (
 province_id integer primary key references fauxlore.provinces(id) on delete cascade,
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 fort_level smallint not null default 0 check(fort_level between 0 and 4),
 wall_level smallint not null default 0 check(wall_level between 0 and 3),
 free_fort boolean not null default false,
 free_wall boolean not null default false,
 created_at timestamptz not null default now()
);
create table fauxlore.garrison_units (
 province_id integer not null references fauxlore.garrison_sites(province_id) on delete cascade,
 unit_id bigint not null references fauxlore.military_unit_catalog(id),
 quantity integer not null check(quantity>0),
 primary key(province_id,unit_id)
);
create table fauxlore.garrison_projects (
 id bigint generated always as identity primary key,
 province_id integer not null references fauxlore.garrison_sites(province_id) on delete cascade,
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 kind text not null check(kind in ('fort','wall')),
 target_level smallint not null,
 turns_remaining smallint not null check(turns_remaining between 1 and 2),
 cost numeric(14,2) not null check(cost>=0),
 started_year integer not null,
 started_turn integer not null,
 completed_year integer,
 completed_turn integer,
 status text not null default 'building' check(status in ('building','completed'))
);
create unique index garrison_one_active_project on fauxlore.garrison_projects(province_id,kind) where status='building';
create table fauxlore.garrison_charges (
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 year integer not null,turn integer not null,
 troops numeric(14,2) not null,fortifications numeric(14,2) not null,
 primary key(state_id,year,turn)
);
do $$ declare table_name text; begin
 foreach table_name in array array['garrison_sites','garrison_units','garrison_projects','garrison_charges'] loop
  execute format('alter table fauxlore.%I enable row level security',table_name);
  execute format('revoke all on fauxlore.%I from public,anon,authenticated',table_name);
 end loop;
end $$;

-- Starting capitals have a free Fortress II and City Walls I.
insert into fauxlore.garrison_sites(province_id,state_id,fort_level,wall_level,free_fort,free_wall)
select m.province_id,m.state_id,3,1,true,true from fauxlore.map_markers m
join fauxlore.state_profiles s on s.state_id=m.state_id where m.type='capital'
on conflict(province_id) do nothing;
create or replace function fauxlore.garrison_capital_created() returns trigger
language plpgsql security definer set search_path='' as $function$
begin
 if new.type='capital' and new.state_id is not null and exists(select 1 from fauxlore.state_profiles where state_id=new.state_id) then
  insert into fauxlore.garrison_sites(province_id,state_id,fort_level,wall_level,free_fort,free_wall)
   values(new.province_id,new.state_id,3,1,true,true) on conflict(province_id) do nothing;
 end if;
 return new;
end $function$;
revoke all on function fauxlore.garrison_capital_created() from public,anon,authenticated;
create trigger garrison_capital_created after insert on fauxlore.map_markers
 for each row execute function fauxlore.garrison_capital_created();

create or replace function fauxlore.garrison_capacity(province_key integer)
returns integer language sql stable security definer set search_path='' as $function$
select coalesce(p.development,0)*case p.province_type when 'Столичная' then 3 when 'Городская' then 2 when 'Регион' then 1 else 0 end
  +case coalesce(g.fort_level,0) when 1 then 100 when 2 then 300 when 3 then 800 when 4 then 1300 else 0 end
  +case coalesce(g.wall_level,0) when 1 then 500 when 2 then 1000 when 3 then 2000 else 0 end
from fauxlore.provinces p left join fauxlore.garrison_sites g on g.province_id=p.id where p.id=province_key
$function$;
revoke all on function fauxlore.garrison_capacity(integer) from public,anon,authenticated;

create or replace function fauxlore.garrison_upkeep(state_key integer)
returns numeric language sql stable security definer set search_path='' as $function$
select coalesce((select sum(round(u.quantity*c.upkeep*.4,2)) from fauxlore.garrison_units u
 join fauxlore.garrison_sites g on g.province_id=u.province_id
 join fauxlore.military_unit_catalog c on c.id=u.unit_id where g.state_id=state_key),0)
 +coalesce((select sum(greatest(0,(case g.fort_level when 1 then 100 when 2 then 200 when 3 then 300 when 4 then 400 else 0 end)
   -case when g.free_fort then 300 else 0 end)
   +greatest(0,(case g.wall_level when 1 then 300 when 2 then 500 when 3 then 700 else 0 end)
   -case when g.free_wall then 300 else 0 end))
 from fauxlore.garrison_sites g where g.state_id=state_key),0)
$function$;
revoke all on function fauxlore.garrison_upkeep(integer) from public,anon,authenticated;

create or replace function public.garrison_api(action text,target_state integer default null,province_key integer default null,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare account_row fauxlore.accounts; sid integer; owner_id integer; site fauxlore.garrison_sites;
 province_row fauxlore.provinces; unit_row fauxlore.military_unit_catalog; quantity_value integer;
 used_value integer; cost_value numeric; balance_value numeric; current_level integer; target_level integer;
 project_kind text; duration integer; project_key bigint; is_owned boolean; marker_key bigint;
begin
 if action='info' then
  return (select jsonb_build_object('province_id',p.id,'fort_level',coalesce(g.fort_level,0),
    'wall_level',coalesce(g.wall_level,0),'capacity',fauxlore.garrison_capacity(p.id),
    'building',(select coalesce(jsonb_agg(jsonb_build_object('kind',pr.kind,'target_level',pr.target_level,
       'turns_remaining',pr.turns_remaining)),'[]'::jsonb) from fauxlore.garrison_projects pr
       where pr.province_id=p.id and pr.status='building'))
    from fauxlore.provinces p left join fauxlore.garrison_sites g on g.province_id=p.id where p.id=province_key);
 end if;
 account_row:=fauxlore.current_account();sid:=target_state;
 if sid is null or not exists(select 1 from fauxlore.state_profiles where state_id=sid) then
  raise sqlstate '22023' using message='Выберите государство'; end if;
 if account_row.role<>'admin' and not exists(select 1 from fauxlore.account_states where account_id=account_row.id and state_id=sid) then
  raise sqlstate '42501' using message='Нет доступа к государству'; end if;
 if action='snapshot' then
  return jsonb_build_object('state_id',sid,
   'troop_upkeep',(select coalesce(sum(round(u.quantity*c.upkeep*.4,2)),0)
     from fauxlore.garrison_units u join fauxlore.garrison_sites g on g.province_id=u.province_id
     join fauxlore.military_unit_catalog c on c.id=u.unit_id where g.state_id=sid),
   'fortification_upkeep',fauxlore.garrison_upkeep(sid)-(select coalesce(sum(round(u.quantity*c.upkeep*.4,2)),0)
     from fauxlore.garrison_units u join fauxlore.garrison_sites g on g.province_id=u.province_id
     join fauxlore.military_unit_catalog c on c.id=u.unit_id where g.state_id=sid),
   'units',(select coalesce(jsonb_agg(to_jsonb(c) order by c.domain,c.id),'[]'::jsonb)
     from fauxlore.military_unit_catalog c where c.active and c.hireable and c.domain in ('land','siege') and (c.state_id is null or c.state_id=sid)),
   'provinces',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'type',p.province_type,
     'development',p.development,'neutral',v.category_id is null,'owned',v.category_id=sid,
     'capacity',fauxlore.garrison_capacity(p.id),'used',coalesce((select sum(u.quantity*c.recruit_cost)
       from fauxlore.garrison_units u join fauxlore.military_unit_catalog c on c.id=u.unit_id where u.province_id=p.id),0),
     'fort_level',coalesce(g.fort_level,0),'wall_level',coalesce(g.wall_level,0),'free_fort',coalesce(g.free_fort,false),
     'free_wall',coalesce(g.free_wall,false),'units',(select coalesce(jsonb_agg(jsonb_build_object('unit_id',u.unit_id,
       'name',c.name,'quantity',u.quantity,'recruits',c.recruit_cost,'upkeep',c.upkeep) order by c.name),'[]'::jsonb)
       from fauxlore.garrison_units u join fauxlore.military_unit_catalog c on c.id=u.unit_id where u.province_id=p.id),
     'projects',(select coalesce(jsonb_agg(jsonb_build_object('kind',pr.kind,'target_level',pr.target_level,
       'turns_remaining',pr.turns_remaining,'cost',pr.cost) order by pr.id),'[]'::jsonb)
       from fauxlore.garrison_projects pr where pr.province_id=p.id and pr.status='building')) order by p.name),'[]'::jsonb)
       from fauxlore.provinces p left join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
       left join fauxlore.garrison_sites g on g.province_id=p.id
       where p.kind='land' and (v.category_id=sid or (v.category_id is null and g.state_id=sid and g.fort_level>0)))
  );
 end if;
 if action not in ('hire','build') then raise sqlstate '22023' using message='Неизвестное действие гарнизона'; end if;
 select * into province_row from fauxlore.provinces where id=province_key and kind='land' for update;
 if not found then raise sqlstate '22023' using message='Выберите сухопутную провинцию'; end if;
 select category_id into owner_id from fauxlore.province_values where province_id=province_key and layer='states';
 is_owned:=coalesce(owner_id=sid,false);
 select * into site from fauxlore.garrison_sites where province_id=province_key for update;
 if action='hire' then
  if not is_owned and not (owner_id is null and site.state_id=sid and site.fort_level>0) then
    raise sqlstate '42501' using message='Гарнизон можно нанять в своей провинции или своём нейтральном форте'; end if;
  quantity_value:=coalesce((payload->>'quantity')::integer,0);
  if quantity_value<1 or quantity_value>100000 then raise sqlstate '22023' using message='Укажите количество от 1 до 100 000'; end if;
  select * into unit_row from fauxlore.military_unit_catalog where id=(payload->>'unit_id')::bigint
    and active and hireable and domain in ('land','siege') and (state_id is null or state_id=sid);
  if not found then raise sqlstate '22023' using message='Этот юнит нельзя нанять в гарнизон'; end if;
  if unit_row.prerequisite='saltpeter' and not exists(select 1 from fauxlore.trade_state_resource_turns r
    where r.state_id=sid and r.resource_name='Селитра'
      and r.production+r.contract_import+r.zone_import>r.consumption+r.contract_export+r.zone_export
      and (r.year,r.turn)=(select year,turn from fauxlore.trade_state_resource_turns order by year desc,turn desc limit 1)) then
    raise sqlstate '22023' using message='Нужен избыток селитры'; end if;
  select coalesce(sum(u.quantity*c.recruit_cost),0) into used_value from fauxlore.garrison_units u
   join fauxlore.military_unit_catalog c on c.id=u.unit_id where u.province_id=province_key;
  if used_value+quantity_value*unit_row.recruit_cost>fauxlore.garrison_capacity(province_key) then
   raise sqlstate '22023' using message='Превышен лимит гарнизона провинции'; end if;
  perform 1 from fauxlore.state_profiles where state_id=sid and recruits>=quantity_value*unit_row.recruit_cost for update;
  if not found then raise sqlstate '22023' using message='Недостаточно рекрутов'; end if;
  cost_value:=round(quantity_value*unit_row.hire_cost*.7,2);
  select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate='Корона' for update;
  if coalesce(balance_value,0)<cost_value then raise sqlstate '22023' using message='Недостаточно G в казне Короны'; end if;
  if site.province_id is null then
   insert into fauxlore.garrison_sites(province_id,state_id) values(province_key,sid);
  end if;
  insert into fauxlore.garrison_units(province_id,unit_id,quantity) values(province_key,unit_row.id,quantity_value)
    on conflict(province_id,unit_id) do update set quantity=fauxlore.garrison_units.quantity+excluded.quantity;
  update fauxlore.state_profiles set recruits=recruits-quantity_value*unit_row.recruit_cost,treasury=treasury-cost_value where state_id=sid;
  update fauxlore.state_treasuries set balance=balance-cost_value,updated_at=now() where state_id=sid and estate='Корона';
  return jsonb_build_object('cost',cost_value,'recruits',quantity_value*unit_row.recruit_cost);
 end if;
 project_kind:=payload->>'kind';target_level:=coalesce((payload->>'level')::integer,0);
 if project_kind not in ('fort','wall') then raise sqlstate '22023' using message='Выберите тип укрепления'; end if;
 if project_kind='fort' and (target_level<1 or target_level>4) or project_kind='wall' and (target_level<1 or target_level>3) then
   raise sqlstate '22023' using message='Недопустимый уровень укрепления'; end if;
 if owner_id is distinct from sid then
  if project_kind<>'fort' or owner_id is not null then raise sqlstate '42501' using message='Городские стены и крепости строятся в своих провинциях'; end if;
  if site.province_id is not null and site.state_id<>sid then raise sqlstate '42501' using message='Нейтральная провинция занята чужим фортом'; end if;
  if target_level<>1 then raise sqlstate '22023' using message='В нейтральной провинции можно построить только форт'; end if;
 else
  if site.province_id is not null and site.state_id<>sid then raise sqlstate '42501' using message='Укрепление закреплено за другим государством'; end if;
 end if;
 if project_kind='wall' and province_row.province_type not in ('Столичная','Городская') then
  raise sqlstate '22023' using message='Стены доступны только столице и городам'; end if;
 if exists(select 1 from fauxlore.garrison_projects where province_id=province_key and status='building') then
  raise sqlstate '22023' using message='В провинции уже строится укрепление'; end if;
 current_level:=case when project_kind='fort' then coalesce(site.fort_level,0) else coalesce(site.wall_level,0) end;
 if target_level<=current_level then raise sqlstate '22023' using message='Укрепление этого уровня уже есть'; end if;
 cost_value:=(case when project_kind='fort' then (array[0,10000,30000,60000,120000])[target_level+1]
   else (array[0,50000,150000,300000])[target_level+1] end)
   -(case when project_kind='fort' then (array[0,10000,30000,60000,120000])[current_level+1]
     else (array[0,50000,150000,300000])[current_level+1] end);
  select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate='Корона' for update;
  if coalesce(balance_value,0)<cost_value then raise sqlstate '22023' using message='Недостаточно G в казне Короны'; end if;
  if site.province_id is null then insert into fauxlore.garrison_sites(province_id,state_id) values(province_key,sid); end if;
  duration:=case when (project_kind='fort' and target_level=4) or (project_kind='wall' and target_level=3) then 2 else 1 end;
  insert into fauxlore.garrison_projects(province_id,state_id,kind,target_level,turns_remaining,cost,started_year,started_turn)
   select province_key,sid,project_kind,target_level,duration,cost,year,turn from fauxlore.game_calendar where singleton
   returning id into project_key;
  update fauxlore.state_treasuries set balance=balance-cost_value,updated_at=now() where state_id=sid and estate='Корона';
  update fauxlore.state_profiles set treasury=treasury-cost_value where state_id=sid;
  return jsonb_build_object('project_id',project_key,'cost',cost_value,'turns',duration);
end $function$;
revoke all on function public.garrison_api(text,integer,integer,jsonb) from public,anon;
grant execute on function public.garrison_api(text,integer,integer,jsonb) to authenticated;
