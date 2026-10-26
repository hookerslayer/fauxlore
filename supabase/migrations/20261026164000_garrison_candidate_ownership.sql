do $migration$
declare definition text; marker text;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 marker:='(v.category_id is null and
      ((g.state_id=sid and g.fort_level>0) or exists';
 if position(marker in definition)=0 then raise exception 'Neutral candidate ownership marker missing'; end if;
 execute replace(definition,marker,'(v.category_id is null and (g.state_id is null or g.state_id=sid) and
      ((g.state_id=sid and g.fort_level>0) or exists');
end $migration$;
