do $migration$
declare definition text; marker text;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 marker:='select province_key,sid,project_kind,target_level,duration,cost,year,turn from fauxlore.game_calendar';
 if position(marker in definition)=0 then raise exception 'Garrison project cost marker missing'; end if;
 definition:=replace(definition,marker,
   'select province_key,sid,project_kind,target_level,duration,cost_value,year,turn from fauxlore.game_calendar');
 marker:='if target_level<>1 then raise sqlstate ''22023'' using message=''В нейтральной провинции можно построить только форт''; end if;';
 if position(marker in definition)=0 then raise exception 'Neutral fort marker missing'; end if;
 definition:=replace(definition,marker,
   'if not exists(select 1 from fauxlore.map_adjacency a
      join lateral jsonb_array_elements_text(a.neighbors->province_key::text) n(value) on true
      join fauxlore.province_values v on v.province_id=n.value::integer and v.layer=''states'' and v.category_id=sid
      join fauxlore.provinces ownp on ownp.id=v.province_id and ownp.kind=''land'' where a.singleton) then
      raise sqlstate ''22023'' using message=''Нейтральный форт строится рядом со своей землёй''; end if;
    '||marker);
 execute definition;
end $migration$;
