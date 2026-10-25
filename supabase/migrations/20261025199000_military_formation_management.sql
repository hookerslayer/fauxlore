-- Add standalone regular army/flotilla creation and formation renaming.
do $migration$
declare fn text; marker text; replacement text; old_actions text; new_actions text;
begin
  fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
  marker:='if action=''admin_unit'' then';
  replacement:=' if action=''create_formation'' then'||E'\n'||
    '  province_key:=(payload->>''province_id'')::integer;'||E'\n'||
    '  if payload->>''domain'' not in (''land'',''naval'') or length(btrim(payload->>''name''))<2 or length(btrim(payload->>''name''))>100 then'||E'\n'||
    '   raise sqlstate ''22023'' using message=''Укажите название (2–100 символов) и тип формирования''; end if;'||E'\n'||
    '  if payload->>''domain''=''naval'' then'||E'\n'||
    '   if not exists(select 1 from fauxlore.map_markers m join fauxlore.map_adjacency a on a.singleton'||E'\n'||
    '     join lateral jsonb_array_elements_text(a.neighbors->m.province_id::text) n(value) on true'||E'\n'||
    '     join fauxlore.province_values v on v.province_id=n.value::integer and v.layer=''states'' and v.category_id=sid'||E'\n'||
    '     where m.province_id=province_key and m.type=''port'') then'||E'\n'||
    '    raise sqlstate ''22023'' using message=''Флотилию можно создать только в порту у собственного берега''; end if;'||E'\n'||
    '  elsif not exists(select 1 from fauxlore.map_markers m join fauxlore.province_values v on v.province_id=m.province_id and v.layer=''states'''||E'\n'||
    '      where m.province_id=province_key and m.type in (''city'',''capital'') and v.category_id=sid) then'||E'\n'||
    '   raise sqlstate ''22023'' using message=''Армию можно создать только в собственном городе''; end if;'||E'\n'||
    '  insert into fauxlore.military_formations(state_id,name,domain,province_id)'||E'\n'||
    '   values(sid,btrim(payload->>''name''),payload->>''domain'',province_key) returning id into formation_key;'||E'\n'||
    '  return jsonb_build_object(''id'',formation_key,''name'',btrim(payload->>''name''),''domain'',payload->>''domain'',''province_id'',province_key);'||E'\n'||
    ' elsif action=''rename_formation'' then'||E'\n'||
    '  formation_key:=(payload->>''formation_id'')::bigint;'||E'\n'||
    '  if length(btrim(payload->>''name''))<2 or length(btrim(payload->>''name''))>100 then'||E'\n'||
    '   raise sqlstate ''22023'' using message=''Название должно содержать от 2 до 100 символов''; end if;'||E'\n'||
    '  update fauxlore.military_formations set name=btrim(payload->>''name'')'||E'\n'||
    '   where id=formation_key and state_id=sid and active and kind=''regular'' returning id into formation_key;'||E'\n'||
    '  if not found then raise sqlstate ''42501'' using message=''Формирование недоступно''; end if;'||E'\n'||
    '  return jsonb_build_object(''id'',formation_key,''name'',btrim(payload->>''name''));'||E'\n'||
    ' elsif action=''admin_unit'' then';
  if position(marker in fn)=0 then raise exception 'Formation management insertion point missing'; end if;
  execute replace(fn,marker,replacement);

  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  old_actions:='''admin_unit'',''admin_mercenary'',''hire_mercenary'',''build_port'',''hire_leader'',''allocate_leader'',''assign_leader''';
  new_actions:='''create_formation'',''rename_formation'',''admin_unit'',''admin_mercenary'',''hire_mercenary'',''build_port'',''hire_leader'',''allocate_leader'',''assign_leader''';
  if position(old_actions in fn)=0 then raise exception 'Formation management RPC dispatch insertion point missing'; end if;
  execute replace(fn,old_actions,new_actions);

  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  marker:='''recruitment'',fauxlore.state_recruitment(sid),';
  replacement:='''recruitment'',fauxlore.state_recruitment(sid),'||E'\n'||
    '   ''leader_limit'',greatest(1,2+floor(coalesce((fauxlore.state_indicators(sid)->>''population'')::numeric,0)/1000000)::integer+'||E'\n'||
    '     case when coalesce((fauxlore.state_indicators(sid)->>''stability'')::numeric,.5)<.3 then -1'||E'\n'||
    '       when coalesce((fauxlore.state_indicators(sid)->>''stability'')::numeric,.5)>=.7 then 1 else 0 end),';
  if position(marker in fn)=0 then raise exception 'Leader limit snapshot insertion point missing'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;
