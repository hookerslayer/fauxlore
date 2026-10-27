-- Make active fortification and port projects visible to players, notify their
-- owners when work starts/completes, and give ports a one-turn construction phase.

create table if not exists fauxlore.military_port_projects (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  sea_province_id integer not null references fauxlore.provinces(id),
  marker_x double precision not null,
  marker_y double precision not null,
  cost numeric(14,2) not null default 10000,
  turns_remaining smallint not null default 1 check (turns_remaining >= 0),
  started_year integer not null,
  started_turn integer not null,
  completed_year integer,
  completed_turn integer,
  status text not null default 'building' check (status in ('building','completed'))
);
create unique index if not exists military_port_one_active_project
  on fauxlore.military_port_projects(sea_province_id) where status='building';
create index if not exists military_port_projects_state_idx
  on fauxlore.military_port_projects(state_id,status);
alter table fauxlore.military_port_projects enable row level security;
revoke all on fauxlore.military_port_projects from public,anon,authenticated;

create or replace function fauxlore.military_start_port_construction(sid integer,payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; province_key integer; x_value double precision; y_value double precision;
        balance_value numeric; project_key bigint; year_value integer; turn_value integer; province_name text;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' and not exists(
    select 1 from fauxlore.account_states where account_id=actor.id and state_id=sid
  ) then raise sqlstate '42501' using message='Нет доступа к государству'; end if;
  province_key:=(payload->>'province_id')::integer;
  x_value:=(payload->>'x')::double precision;
  y_value:=(payload->>'y')::double precision;
  select p.name into province_name from fauxlore.provinces p
   where p.id=province_key and p.kind='sea'
     and x_value>=(p.bbox->>0)::double precision and x_value<(p.bbox->>2)::double precision
     and y_value>=(p.bbox->>1)::double precision and y_value<(p.bbox->>3)::double precision;
  if not found then raise sqlstate '22023' using message='Укажите точку внутри морской провинции'; end if;
  if exists(select 1 from fauxlore.map_markers where province_id=province_key and type='port') then
    raise sqlstate '22023' using message='В этой провинции уже есть порт'; end if;
  if exists(select 1 from fauxlore.military_port_projects where sea_province_id=province_key and status='building') then
    raise sqlstate '22023' using message='В этой провинции уже строится порт'; end if;
  if not exists(select 1 from fauxlore.map_adjacency a
      cross join lateral jsonb_array_elements_text(a.neighbors->province_key::text) n(value)
      join fauxlore.province_values v on v.province_id=n.value::integer and v.layer='states' and v.category_id=sid
      join fauxlore.provinces p on p.id=v.province_id and p.kind='land' where a.singleton) then
    raise sqlstate '22023' using message='Нужен контролируемый соседний берег'; end if;
  select balance into balance_value from fauxlore.state_treasuries
   where state_id=sid and estate='Корона' for update;
  if coalesce(balance_value,0)<10000 then raise sqlstate '22023' using message='Для порта нужно 10 000 G'; end if;
  select year,turn into year_value,turn_value from fauxlore.game_calendar where singleton;
  insert into fauxlore.military_port_projects(state_id,sea_province_id,marker_x,marker_y,cost,turns_remaining,started_year,started_turn)
   values(sid,province_key,x_value,y_value,10000,1,year_value,turn_value) returning id into project_key;
  update fauxlore.state_treasuries set balance=balance-10000,updated_at=now()
   where state_id=sid and estate='Корона';
  update fauxlore.state_profiles set treasury=treasury-10000 where state_id=sid;
  insert into fauxlore.notifications(account_id,kind,title,message)
   select a.account_id,'construction','Строительство началось',
     'Началось строительство порта в провинции «'||province_name||'». Завершение — после следующего хода.'
   from fauxlore.account_states a where a.state_id=sid;
  return jsonb_build_object('project_id',project_key,'cost',10000,'turns',1);
end
$function$;
revoke all on function fauxlore.military_start_port_construction(integer,jsonb) from public,anon,authenticated;

do $migration$
declare definition text; start_marker text; end_marker text; first_pos integer; second_pos integer;
begin
  definition:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
  start_marker:=' elsif action=''build_port'' then';
  end_marker:=' elsif action=''hire_leader'' then';
  first_pos:=position(start_marker in definition);
  second_pos:=position(end_marker in definition);
  if first_pos=0 or second_pos<=first_pos then raise exception 'Port build action block was not found'; end if;
  definition:=substring(definition from 1 for first_pos-1)||
    ' elsif action=''build_port'' then'||E'\n  return fauxlore.military_start_port_construction(sid,payload);\n'||
    substring(definition from second_pos);
  execute definition;
end
$migration$;

create or replace function fauxlore.complete_military_port_projects()
returns trigger language plpgsql security definer set search_path='' as $function$
declare project_row fauxlore.military_port_projects; marker_key bigint; province_name text;
begin
  if new.year=old.year and new.turn=old.turn then return new; end if;
  for project_row in select * from fauxlore.military_port_projects where status='building' order by id for update loop
    select name into province_name from fauxlore.provinces where id=project_row.sea_province_id;
    insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)
      values(project_row.sea_province_id,project_row.marker_x,project_row.marker_y,'port','Порт '||province_name,project_row.state_id)
      returning id into marker_key;
    insert into fauxlore.military_port_builds(state_id,sea_province_id,marker_id,cost)
      values(project_row.state_id,project_row.sea_province_id,marker_key,project_row.cost);
    update fauxlore.military_port_projects set status='completed',turns_remaining=0,
      completed_year=new.year,completed_turn=new.turn where id=project_row.id;
    insert into fauxlore.notifications(account_id,kind,title,message)
      select a.account_id,'construction','Строительство завершено',
        'Порт в провинции «'||province_name||'» построен и готов к использованию.'
      from fauxlore.account_states a where a.state_id=project_row.state_id;
  end loop;
  return new;
end
$function$;
revoke all on function fauxlore.complete_military_port_projects() from public,anon,authenticated;
create trigger military_port_complete_on_turn after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.complete_military_port_projects();

create or replace function fauxlore.notify_garrison_project_started()
returns trigger language plpgsql security definer set search_path='' as $function$
declare province_name text; title_value text;
begin
  select name into province_name from fauxlore.provinces where id=new.province_id;
  title_value:=case when new.kind='fort' then 'Крепость' else 'Городские стены' end;
  insert into fauxlore.notifications(account_id,kind,title,message)
    select a.account_id,'construction','Строительство началось',
      'Началось строительство: '||title_value||' в провинции «'||province_name||'». Осталось ходов: '||new.turns_remaining||'.'
    from fauxlore.account_states a where a.state_id=new.state_id;
  return new;
end
$function$;
revoke all on function fauxlore.notify_garrison_project_started() from public,anon,authenticated;
create trigger garrison_project_started after insert on fauxlore.garrison_projects
  for each row execute function fauxlore.notify_garrison_project_started();

create or replace function fauxlore.capture_test_turn_port_projects()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
    'military_port_projects',(select coalesce(jsonb_agg(to_jsonb(x) order by id),'[]'::jsonb)
      from fauxlore.military_port_projects x));
  return new;
end
$function$;
revoke all on function fauxlore.capture_test_turn_port_projects() from public,anon,authenticated;
create trigger turn_test_snapshot_capture_port_projects before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_port_projects();

create or replace function fauxlore.restore_test_turn_port_projects()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if jsonb_typeof(old.payload->'military_port_projects')<>'array' then return old; end if;
  lock table fauxlore.military_port_projects in access exclusive mode;
  delete from fauxlore.military_port_projects;
  insert into fauxlore.military_port_projects overriding system value
    select * from jsonb_populate_recordset(null::fauxlore.military_port_projects,old.payload->'military_port_projects');
  return old;
end
$function$;
revoke all on function fauxlore.restore_test_turn_port_projects() from public,anon,authenticated;
create trigger turn_test_snapshot_restore_port_projects before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_port_projects();

-- Expose active works alongside military tokens. The result remains filtered by
-- the same province visibility rules as the military map layer.
create or replace function public.military_map_api()
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; actor_states integer[]; visible_provinces integer[]; all_visible boolean;
begin
  actor:=fauxlore.current_account();
  all_visible:=actor.role='admin';
  select coalesce(array_agg(state_id order by state_id),'{}'::integer[]) into actor_states
    from fauxlore.account_states where account_id=actor.id;
  if all_visible then visible_provinces:=null;
  else
    select coalesce(array_agg(distinct visible.province_id),'{}'::integer[]) into visible_provinces
    from (
      select pv.province_id from fauxlore.province_values pv
       where pv.layer='states' and pv.category_id=any(actor_states)
      union
      select neighbor.value::integer from fauxlore.province_values pv
       cross join fauxlore.map_adjacency graph
       cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->pv.province_id::text,'[]'::jsonb)) neighbor(value)
       where pv.layer='states' and pv.category_id=any(actor_states)
      union
      select f.province_id from fauxlore.military_formations f where f.active and f.state_id=any(actor_states)
      union
      select neighbor.value::integer from fauxlore.military_formations f
       cross join fauxlore.map_adjacency graph
       cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->f.province_id::text,'[]'::jsonb)) neighbor(value)
       where f.active and f.state_id=any(actor_states)
    ) visible;
  end if;
  return jsonb_build_object(
    'formations',(select coalesce(jsonb_agg(jsonb_build_object(
       'id',f.id,'name',f.name,'domain',f.domain,'kind',f.kind,'province_id',f.province_id,
       'province_name',p.name,'x',(p.center->>0)::numeric,'y',(p.center->>1)::numeric,
       'state_id',f.state_id,'state_name',state.name,'state_color',state.color,
       'leader_name',leader.name,'units',coalesce((select jsonb_agg(jsonb_build_object('unit_id',u.id,'name',u.name,'quantity',fu.quantity) order by u.name)
          from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
          where fu.formation_id=f.id),'[]'::jsonb),
       'total_quantity',coalesce((select sum(fu.quantity) from fauxlore.military_formation_units fu where fu.formation_id=f.id),0)
     ) order by f.province_id,f.id),'[]'::jsonb)
     from fauxlore.military_formations f join fauxlore.provinces p on p.id=f.province_id
      join fauxlore.map_categories state on state.layer='states' and state.id=f.state_id
      left join fauxlore.military_leaders leader on leader.id=f.leader_id
     where f.active and (all_visible or f.state_id=any(actor_states) or f.province_id=any(visible_provinces))),
    'garrisons',(select coalesce(jsonb_agg(jsonb_build_object(
       'token_type','garrison','province_id',g.province_id,'province_name',p.name,
       'x',(p.center->>0)::numeric,'y',(p.center->>1)::numeric,'state_id',g.state_id,
       'state_name',state.name,'state_color',state.color,'fort_level',g.fort_level,'wall_level',g.wall_level,
       'units',coalesce((select jsonb_agg(jsonb_build_object('unit_id',u.id,'name',u.name,'quantity',gu.quantity) order by u.name)
          from fauxlore.garrison_units gu join fauxlore.military_unit_catalog u on u.id=gu.unit_id
          where gu.province_id=g.province_id),'[]'::jsonb),
       'total_quantity',coalesce((select sum(gu.quantity) from fauxlore.garrison_units gu where gu.province_id=g.province_id),0)
     ) order by g.province_id),'[]'::jsonb)
     from fauxlore.garrison_sites g join fauxlore.provinces p on p.id=g.province_id
      join fauxlore.map_categories state on state.layer='states' and state.id=g.state_id
     where (all_visible or g.state_id=any(actor_states) or g.province_id=any(visible_provinces))
       and exists(select 1 from fauxlore.garrison_units gu where gu.province_id=g.province_id)),
    'constructions',(select coalesce(jsonb_agg(project order by project->>'province_id',project->>'kind'),'[]'::jsonb)
      from (
        select jsonb_build_object('id',pr.id,'kind',pr.kind,'province_id',pr.province_id,'province_name',p.name,
          'name',case when pr.kind='fort' then case when pr.target_level=1 then 'Форт' else 'Крепость' end
                     else 'Городские стены' end,
          'target_level',pr.target_level,'turns_remaining',pr.turns_remaining,'cost',pr.cost,
          'x',coalesce(pr.marker_x,(p.center->>0)::double precision),'y',coalesce(pr.marker_y,(p.center->>1)::double precision),
          'state_id',pr.state_id,'state_name',state.name,'state_color',state.color,'object_type','fortress') as project
        from fauxlore.garrison_projects pr join fauxlore.provinces p on p.id=pr.province_id
          join fauxlore.map_categories state on state.layer='states' and state.id=pr.state_id
        where pr.status='building' and (all_visible or pr.state_id=any(actor_states) or pr.province_id=any(visible_provinces))
        union all
        select jsonb_build_object('id',pr.id,'kind','port','province_id',pr.sea_province_id,'province_name',p.name,
          'name','Порт','target_level',1,'turns_remaining',pr.turns_remaining,'cost',pr.cost,
          'x',pr.marker_x,'y',pr.marker_y,'state_id',pr.state_id,'state_name',state.name,
          'state_color',state.color,'object_type','port') as project
        from fauxlore.military_port_projects pr join fauxlore.provinces p on p.id=pr.sea_province_id
          join fauxlore.map_categories state on state.layer='states' and state.id=pr.state_id
        where pr.status='building' and (all_visible or pr.state_id=any(actor_states) or pr.sea_province_id=any(visible_provinces))
      ) active_projects),
    'fog_of_war',not all_visible
  );
end
$function$;
revoke all on function public.military_map_api() from public,anon;
grant execute on function public.military_map_api() to authenticated;
notify pgrst,'reload schema';
