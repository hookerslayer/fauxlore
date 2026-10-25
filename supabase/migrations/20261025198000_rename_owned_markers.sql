-- Allow a state's owner to rename its markers; admins may rename every marker.
do $migration$
declare fn text; marker text; route text;
begin
  fn:=pg_get_functiondef('fauxlore.api(text,text,jsonb,uuid)'::regprocedure);
  marker:='  elsif path=''profile/avatar'' and method=''POST'' then';
  route:='  elsif path~''^markers/[0-9]+/name$'' and method=''PATCH'' then'||E'\n'||
    '    marker_id:=split_part(path,''/'',2)::bigint;'||E'\n'||
    '    if body-''name''<>''{}''::jsonb or jsonb_typeof(body->''name'') is distinct from ''string'' or'||E'\n'||
    '      length(btrim(body->>''name''))<1 or length(btrim(body->>''name''))>120 then'||E'\n'||
    '      raise sqlstate ''22023'' using message=''Название должно содержать от 1 до 120 символов''; end if;'||E'\n'||
    '    select * into m from fauxlore.map_markers where id=marker_id for update;'||E'\n'||
    '    if not found then raise sqlstate ''P0002'' using message=''Маркер не найден''; end if;'||E'\n'||
    '    if a.role<>''admin'' and (m.state_id is null or not exists(select 1 from fauxlore.account_states s where s.account_id=a.id and s.state_id=m.state_id)) then'||E'\n'||
    '      raise sqlstate ''42501'' using message=''Можно переименовывать только маркеры своего государства''; end if;'||E'\n'||
    '    update fauxlore.map_markers set name=fauxlore.normalize(''name'',body->''name'')#>>''{}'' where id=marker_id returning * into m;'||E'\n'||
    '    result:=to_jsonb(m);'||E'\n'||marker;
  if position(marker in fn)=0 then raise exception 'Marker rename insertion point missing'; end if;
  execute replace(fn,marker,route);
  fn:=pg_get_functiondef('fauxlore.api(text,text,jsonb,uuid)'::regprocedure);
  marker:='or path like ''provinces/%'' then';
  route:='or path like ''provinces/%'' or path like ''markers/%'' then';
  if position(marker in fn)=0 then raise exception 'Marker rename revision check insertion point missing'; end if;
  execute replace(fn,marker,route);
end
$migration$;
