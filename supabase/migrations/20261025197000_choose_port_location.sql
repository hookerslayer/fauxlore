-- Let players place the port marker at a chosen point inside its sea province.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
  old_fragment:='  insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)'||E'\n'||
    '   select p.id,(p.center->>0)::double precision,(p.center->>1)::double precision,''port'',''Порт ''||p.name,sid'||E'\n'||
    '   from fauxlore.provinces p where p.id=province_key returning id into marker_key;';
  new_fragment:='  if jsonb_typeof(payload->''x'') is distinct from ''number'' or jsonb_typeof(payload->''y'') is distinct from ''number'' or'||E'\n'||
    '    not exists(select 1 from fauxlore.provinces p where p.id=province_key and'||E'\n'||
    '      (payload->>''x'')::numeric>=(p.bbox->>0)::numeric and (payload->>''x'')::numeric<(p.bbox->>2)::numeric and'||E'\n'||
    '      (payload->>''y'')::numeric>=(p.bbox->>1)::numeric and (payload->>''y'')::numeric<(p.bbox->>3)::numeric) then'||E'\n'||
    '   raise sqlstate ''22023'' using message=''Укажите точку внутри выбранной морской провинции''; end if;'||E'\n'||
    '  insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)'||E'\n'||
    '   select p.id,(payload->>''x'')::double precision,(payload->>''y'')::double precision,''port'',''Порт ''||p.name,sid'||E'\n'||
    '   from fauxlore.provinces p where p.id=province_key returning id into marker_key;';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate port marker insertion'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
