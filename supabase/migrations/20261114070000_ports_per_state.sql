-- Несколько портов в одной морской провинции: лимит — один порт на государство.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch port construction outside production candidate';
  end if;
end
$guard$;

drop index if exists fauxlore.military_one_port_per_sea_province;
create unique index if not exists military_one_port_per_state_province
  on fauxlore.map_markers(province_id, state_id) where type = 'port';

drop index if exists fauxlore.military_port_one_active_project;
create unique index if not exists military_port_one_active_project_per_state
  on fauxlore.military_port_projects(sea_province_id, state_id) where status = 'building';

do $patch$
declare definition text;
begin
  select pg_get_functiondef('fauxlore.military_start_port_construction(integer,jsonb)'::regprocedure) into definition;
  if position($m$province_id=province_key and type='port') then$m$ in definition) = 0 then
    raise exception 'port existence check not found';
  end if;
  definition := replace(definition,
    $m$province_id=province_key and type='port') then$m$,
    $m$province_id=province_key and type='port' and state_id=sid) then$m$);
  definition := replace(definition,
    $m$message='В этой провинции уже есть порт'$m$,
    $m$message='У этого государства уже есть порт в этой провинции'$m$);
  if position($m$sea_province_id=province_key and status='building') then$m$ in definition) = 0 then
    raise exception 'port project check not found';
  end if;
  definition := replace(definition,
    $m$sea_province_id=province_key and status='building') then$m$,
    $m$sea_province_id=province_key and status='building' and state_id=sid) then$m$);
  definition := replace(definition,
    $m$message='В этой провинции уже строится порт'$m$,
    $m$message='У этого государства уже строится порт в этой провинции'$m$);
  execute definition;
end
$patch$;

-- Снимок военного дела: портом считается только собственный маркер государства.
do $patch$
declare definition text;
begin
  select pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure) into definition;
  definition := replace(definition,
    $m$m.province_id=p.id and m.type='port'),'controlled'$m$,
    $m$m.province_id=p.id and m.type='port' and m.state_id=sid),'controlled'$m$);
  definition := replace(definition,
    $m$m.province_id=p.id and m.type='port')
    )) or (is_admin and p.kind='land'))$m$,
    $m$m.province_id=p.id and m.type='port' and m.state_id=sid)
    )) or (is_admin and p.kind='land'))$m$);
  definition := replace(definition,
    $m$m.province_id=province_key and m.type='port') then$m$,
    $m$m.province_id=province_key and m.type='port' and m.state_id=sid) then$m$);
  execute definition;
end
$patch$;
