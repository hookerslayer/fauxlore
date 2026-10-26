-- Neutral forts use the same land-colonization availability gates.
do $migration$
declare definition text; marker text;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 marker:='if not exists(select 1 from fauxlore.map_adjacency a
      join lateral jsonb_array_elements_text(a.neighbors->province_key::text) n(value) on true';
 if position(marker in definition)=0 then raise exception 'Neutral fort adjacency marker missing'; end if;
 definition:=replace(definition,marker,
  'if exists(select 1 from fauxlore.colonization_missions m where m.province_id=province_key and m.status=''active'') then
      raise sqlstate ''22023'' using message=''Эта провинция уже колонизируется''; end if;
    if (select count(*) from fauxlore.colonization_attempts a cross join fauxlore.game_calendar c
        where a.state_id=sid and a.year=c.year and a.turn=c.turn)>=2 then
      raise sqlstate ''22023'' using message=''В этом ходу уже исчерпаны попытки колонизации''; end if;
    if exists(select 1 from fauxlore.colonization_attempts a cross join fauxlore.game_calendar c
        where a.state_id=sid and a.province_id=province_key and a.year=c.year and a.turn=c.turn) then
      raise sqlstate ''22023'' using message=''Эту провинцию уже пытались колонизировать в этом ходу''; end if;
    '||marker);
 execute definition;
end $migration$;
