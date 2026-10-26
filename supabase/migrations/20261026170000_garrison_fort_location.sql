alter table fauxlore.garrison_projects add column marker_x double precision, add column marker_y double precision;

do $migration$
declare definition text; marker text;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 marker:='if site.province_id is null then insert into fauxlore.garrison_sites(province_id,state_id) values(province_key,sid); end if;
  duration:=';
 if position(marker in definition)=0 then raise exception 'Build insertion marker missing'; end if;
 definition:=replace(definition,marker,
  'if project_kind=''fort'' and current_level=0 and
    (jsonb_typeof(payload->''x'') is distinct from ''number'' or jsonb_typeof(payload->''y'') is distinct from ''number'' or
     not ((payload->>''x'')::numeric>=(province_row.bbox->>0)::numeric and (payload->>''x'')::numeric<(province_row.bbox->>2)::numeric and
      (payload->>''y'')::numeric>=(province_row.bbox->>1)::numeric and (payload->>''y'')::numeric<(province_row.bbox->>3)::numeric)) then
      raise sqlstate ''22023'' using message=''Укажите точку внутри выбранной провинции''; end if;
   '||marker);
 marker:='insert into fauxlore.garrison_projects(province_id,state_id,kind,target_level,turns_remaining,cost,started_year,started_turn)
   select province_key,sid,project_kind,target_level,duration,cost_value,year,turn';
 if position(marker in definition)=0 then raise exception 'Project insert marker missing'; end if;
 definition:=replace(definition,marker,
  'insert into fauxlore.garrison_projects(province_id,state_id,kind,target_level,turns_remaining,cost,started_year,started_turn,marker_x,marker_y)
   select province_key,sid,project_kind,target_level,duration,cost_value,year,turn,
    case when project_kind=''fort'' then (payload->>''x'')::double precision end,
    case when project_kind=''fort'' then (payload->>''y'')::double precision end');
 execute definition;
 definition:=pg_get_functiondef('fauxlore.complete_garrison_projects()'::regprocedure);
 marker:='(p.center->>0)::double precision,(p.center->>1)::double precision';
 if position(marker in definition)=0 then raise exception 'Marker location missing'; end if;
 execute replace(definition,marker,'coalesce(project_row.marker_x,(p.center->>0)::double precision),coalesce(project_row.marker_y,(p.center->>1)::double precision)');
end $migration$;
