-- Extend the checked public RPC with the remaining first-stage military actions.
create or replace function fauxlore.military_actions_extra(action text,sid integer,payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare account_row fauxlore.accounts; group_row fauxlore.mercenary_groups; unit_row fauxlore.military_unit_catalog;
 rec jsonb; province_key integer; formation_key bigint; leader_key bigint; marker_key bigint; amount integer;
 price numeric; balance_value numeric; tradition_value numeric; prestige_value numeric; limit_value integer; existing_count integer;
 dice integer; fixed_points integer; free_points integer; skills jsonb; skill_names text[]; skill_name text;
begin
 account_row:=fauxlore.current_account();
 if action='admin_mercenary' then
  if account_row.role<>'admin' then raise sqlstate '42501' using message='Только администратор создаёт наёмников'; end if;
  province_key:=(payload->>'city_province_id')::integer;
  if not exists(select 1 from fauxlore.map_markers where province_id=province_key and type in ('city','capital')) then
   raise sqlstate '22023' using message='Группа должна базироваться в городе'; end if;
  if jsonb_typeof(payload->'composition')<>'array' or jsonb_array_length(payload->'composition')=0 then
   raise sqlstate '22023' using message='Укажите состав отряда'; end if;
  for rec in select value from jsonb_array_elements(payload->'composition') loop
   if coalesce((rec->>'quantity')::integer,0)<1 or not exists(select 1 from fauxlore.military_unit_catalog where id=(rec->>'unit_id')::bigint and domain='land') then
    raise sqlstate '22023' using message='Состав наёмников содержит недопустимый юнит'; end if;
  end loop;
  insert into fauxlore.mercenary_groups(name,city_province_id,leader_name,leader_skills,composition,price)
   values(left(btrim(payload->>'name'),100),province_key,left(btrim(payload->>'leader_name'),100),coalesce(payload->'leader_skills','{}'::jsonb),
     payload->'composition',(payload->>'price')::numeric) returning id into group_row.id;
  return jsonb_build_object('id',group_row.id);
 elsif action='hire_mercenary' then
  select * into group_row from fauxlore.mercenary_groups where id=(payload->>'group_id')::bigint and active for update;
  if not found then raise sqlstate '22023' using message='Наёмная группа не найдена'; end if;
  if exists(select 1 from fauxlore.military_formations where mercenary_group_id=group_row.id and active) then
   raise sqlstate '22023' using message='Группа уже нанята'; end if;
  select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate='Корона' for update;
  if coalesce(balance_value,0)<group_row.price then raise sqlstate '22023' using message='Недостаточно монет'; end if;
  insert into fauxlore.military_formations(state_id,name,domain,kind,province_id,mercenary_group_id)
   values(sid,group_row.name,'land','mercenary',group_row.city_province_id,group_row.id) returning id into formation_key;
  for rec in select value from jsonb_array_elements(group_row.composition) loop
   insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
    values(formation_key,(rec->>'unit_id')::bigint,(rec->>'quantity')::integer);
  end loop;
  update fauxlore.state_treasuries set balance=balance-group_row.price,updated_at=now() where state_id=sid and estate='Корона';
  update fauxlore.state_profiles set treasury=treasury-group_row.price where state_id=sid;
  return jsonb_build_object('formation_id',formation_key,'cost',group_row.price);
 elsif action='build_port' then
  province_key:=(payload->>'province_id')::integer;
  if not exists(select 1 from fauxlore.provinces where id=province_key and kind='sea') then
   raise sqlstate '22023' using message='Порт строится в морской провинции'; end if;
  if exists(select 1 from fauxlore.map_markers where province_id=province_key and type='port') then
   raise sqlstate '22023' using message='В этой провинции уже есть порт'; end if;
  if not exists(select 1 from fauxlore.map_adjacency a join lateral jsonb_array_elements_text(a.neighbors->province_key::text) n(value) on true
     join fauxlore.province_values v on v.province_id=n.value::integer and v.layer='states' and v.category_id=sid
     join fauxlore.provinces p on p.id=v.province_id and p.kind='land' where a.singleton) then
   raise sqlstate '22023' using message='Нужен контролируемый соседний берег'; end if;
  select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate='Корона' for update;
  if coalesce(balance_value,0)<10000 then raise sqlstate '22023' using message='Для порта нужно 10 000 G'; end if;
  insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)
   select p.id,(p.center->>0)::double precision,(p.center->>1)::double precision,'port','Порт '||p.name,sid
   from fauxlore.provinces p where p.id=province_key returning id into marker_key;
  insert into fauxlore.military_port_builds(state_id,sea_province_id,marker_id) values(sid,province_key,marker_key);
  update fauxlore.state_treasuries set balance=balance-10000,updated_at=now() where state_id=sid and estate='Корона';
  update fauxlore.state_profiles set treasury=treasury-10000 where state_id=sid;
  return jsonb_build_object('marker_id',marker_key,'cost',10000);
 elsif action='hire_leader' then
  if payload->>'domain' not in ('land','naval') or payload->>'estate' not in ('Знать','Духовенство','Горожане','Крестьяне') then
   raise sqlstate '22023' using message='Выберите тип и сословие командира'; end if;
  select case when payload->>'domain'='land' then land else naval end into tradition_value
    from fauxlore.military_traditions where state_id=sid for update;
  select prestige into prestige_value from fauxlore.state_profiles where state_id=sid for update;
  if prestige_value<10 or tradition_value<5 then raise sqlstate '22023' using message='Нужно 10 ОП и 5% традиций'; end if;
  select count(*) into existing_count from fauxlore.military_leaders where state_id=sid and status in ('active','wounded','captured');
  select greatest(1,2+floor(coalesce((fauxlore.state_indicators(sid)->>'population')::numeric,0)/1000000)::integer+
    case when coalesce((fauxlore.state_indicators(sid)->>'stability')::numeric,.5)<.3 then -1
      when coalesce((fauxlore.state_indicators(sid)->>'stability')::numeric,.5)>=.7 then 1 else 0 end) into limit_value;
  price:=2500*greatest(1,existing_count-limit_value+2);
  select balance into balance_value from fauxlore.state_treasuries where state_id=sid and estate='Корона' for update;
  if coalesce(balance_value,0)<price then raise sqlstate '22023' using message='Недостаточно монет'; end if;
  dice:=floor(random()*6)::integer+1;
  if tradition_value<=20 then fixed_points:=(dice+1)/2; free_points:=(dice-1)%2;
  elsif tradition_value<=50 then fixed_points:=(dice+1)/2+1; free_points:=(dice-1)%2;
  elsif tradition_value<=80 then fixed_points:=(dice+1)/2+2; free_points:=1+(dice-1)%2;
  else fixed_points:=(dice+1)/2+3; free_points:=case when dice<=2 then 1+(dice-1)%2 else case when dice<=4 then 1+(dice-3)%2 else 2+(dice-5)%2 end end;
  end if;
  skill_names:=case when payload->>'domain'='land' then array['Натиск','Огонь','Маневренность','Инженерные познания']
    else array['Залп','Натиск','Навигация','Блокада'] end;
  skills:=jsonb_build_object(skill_names[1],0,skill_names[2],0,skill_names[3],0,skill_names[4],0);
  for amount in 1..fixed_points loop
   skill_name:=skill_names[floor(random()*4)::integer+1];
   skills:=jsonb_set(skills,array[skill_name],to_jsonb(least(6,(skills->>skill_name)::integer+1)));
  end loop;
  insert into fauxlore.military_leaders(state_id,name,domain,estate,skills,rolls)
   values(sid,left(btrim(payload->>'name'),100),payload->>'domain',payload->>'estate',skills,
    jsonb_build_object('d6',dice,'fixed_points',fixed_points,'free_points',free_points,'tradition_before',tradition_value)) returning id into leader_key;
  update fauxlore.military_traditions set land=case when payload->>'domain'='land' then land-5 else land end,
    naval=case when payload->>'domain'='naval' then naval-5 else naval end where state_id=sid;
  update fauxlore.state_profiles set prestige=prestige-10,treasury=treasury-price where state_id=sid;
  update fauxlore.state_treasuries set balance=balance-price,updated_at=now() where state_id=sid and estate='Корона';
  return jsonb_build_object('leader_id',leader_key,'cost',price,'skills',skills,'free_points',free_points,'d6',dice);
 elsif action='assign_leader' then
  formation_key:=(payload->>'formation_id')::bigint;leader_key:=nullif(payload->>'leader_id','')::bigint;
  if not exists(select 1 from fauxlore.military_formations where id=formation_key and state_id=sid and active and kind='regular') then
   raise sqlstate '22023' using message='Формирование не найдено'; end if;
  if leader_key is not null and (not exists(select 1 from fauxlore.military_leaders l join fauxlore.military_formations f on f.id=formation_key
    where l.id=leader_key and l.state_id=sid and l.status='active' and l.domain=f.domain)
    or exists(select 1 from fauxlore.military_formations where leader_id=leader_key and id<>formation_key and active)) then
   raise sqlstate '22023' using message='Командир недоступен'; end if;
  update fauxlore.military_formations set leader_id=leader_key where id=formation_key;
  return jsonb_build_object('ok',true);
 end if;
 raise sqlstate '22023' using message='Неизвестная военная операция';
end $$;
revoke all on function fauxlore.military_actions_extra(text,integer,jsonb) from public,anon,authenticated;
do $$ declare fn text; marker text:=' elsif action=''propose'' then'; begin
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 if position(marker in fn)=0 then raise exception 'military_api insertion point missing'; end if;
 execute replace(fn,marker,' elsif action in (''admin_mercenary'',''hire_mercenary'',''build_port'',''hire_leader'',''assign_leader'') then
  return fauxlore.military_actions_extra(action,sid,payload);'||marker);
end $$;
