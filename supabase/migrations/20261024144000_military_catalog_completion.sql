alter table fauxlore.military_unit_catalog add column if not exists hireable boolean not null default true;
alter table fauxlore.military_unit_catalog add column if not exists version integer not null default 1 check(version>0);
alter table fauxlore.military_unit_catalog drop constraint if exists military_unit_catalog_name_key;
create unique index if not exists military_unit_catalog_version_key on fauxlore.military_unit_catalog(coalesce(state_id,0),name,version);
insert into fauxlore.military_unit_catalog(name,domain,category,health,damage,charge_damage,armor,initiative,power,capacity,recruit_cost,hire_cost,upkeep,hireable)
 values('Рыцарь','land','Кавалерия',10,8,10,10,4,16,0,1,0,24,false),
 ('Таран','siege','Осада',10,0,null,0,0,0,0,12,0,0,false),
 ('Осадная башня','siege','Осада',10,0,null,0,0,0,0,8,0,0,false)
on conflict do nothing;
do $$ declare fn text; old_fragment text; new_fragment text; begin
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 old_fragment:='where id=(payload->>''unit_id'')::bigint and active and (state_id is null or state_id=sid)';
 new_fragment:='where id=(payload->>''unit_id'')::bigint and active and hireable and (state_id is null or state_id=sid)';
 if position(old_fragment in fn)=0 then raise exception 'Military hireability marker missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
 fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
 old_fragment:=' if action=''admin_mercenary'' then';
 new_fragment:=' if action=''admin_unit'' then
  if account_row.role<>''admin'' then raise sqlstate ''42501'' using message=''Только администратор утверждает национальные юниты''; end if;
  if coalesce(length(btrim(payload->>''name'')),0)<2 or payload->>''domain'' not in (''land'',''naval'',''siege'') then
   raise sqlstate ''22023'' using message=''Укажите название и род войск''; end if;
  update fauxlore.military_unit_catalog set active=false where state_id=sid and name=left(btrim(payload->>''name''),80);
  insert into fauxlore.military_unit_catalog(name,domain,category,health,damage,charge_damage,armor,initiative,power,capacity,
    recruit_cost,hire_cost,upkeep,prerequisite,state_id,version)
  values(left(btrim(payload->>''name''),80),payload->>''domain'',left(btrim(payload->>''category''),80),
    (payload->>''health'')::integer,(payload->>''damage'')::numeric,nullif(payload->>''charge_damage'','''')::numeric,
    (payload->>''armor'')::numeric,(payload->>''initiative'')::numeric,coalesce((payload->>''power'')::numeric,0),
    coalesce((payload->>''capacity'')::integer,0),(payload->>''recruit_cost'')::integer,(payload->>''hire_cost'')::numeric,
    (payload->>''upkeep'')::numeric,coalesce(payload->>''prerequisite'',''none''),sid,
    (select coalesce(max(version),0)+1 from fauxlore.military_unit_catalog where state_id=sid and name=left(btrim(payload->>''name''),80)))
  returning id into leader_key;
  return jsonb_build_object(''unit_id'',leader_key);
 elsif action=''admin_mercenary'' then';
 if position(old_fragment in fn)=0 then raise exception 'National unit insertion point missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 old_fragment:='''admin_mercenary'',''hire_mercenary'',''build_port'',''hire_leader'',''assign_leader''';
 new_fragment:='''admin_unit'',''admin_mercenary'',''hire_mercenary'',''build_port'',''hire_leader'',''assign_leader''';
 if position(old_fragment in fn)=0 then raise exception 'National unit dispatch marker missing'; end if;
 execute replace(fn,old_fragment,new_fragment);
end $$;
