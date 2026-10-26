-- Colony attempt quotas are temporary action limits; fort placement follows the
-- target's geographic land/sea accessibility and occupation status.
do $migration$
declare definition text; first_marker text; last_marker text; start_at integer; end_at integer;
begin
 definition:=pg_get_functiondef('public.garrison_api(text,integer,integer,jsonb)'::regprocedure);
 first_marker:='if (select count(*) from fauxlore.colonization_attempts a cross join fauxlore.game_calendar c';
 last_marker:='if not fauxlore.neutral_fort_colonizable(sid,province_key) then';
 start_at:=position(first_marker in definition);end_at:=position(last_marker in definition);
 if start_at=0 or end_at<=start_at then raise exception 'Neutral fort quota section missing'; end if;
 execute substr(definition,1,start_at-1)||substr(definition,end_at);

 definition:=pg_get_functiondef('fauxlore.neutral_fort_colonizable(integer,integer)'::regprocedure);
 first_marker:='if (select count(*) from fauxlore.colonization_attempts a cross join fauxlore.game_calendar c';
 last_marker:='select neighbors into graph from fauxlore.map_adjacency where singleton;';
 start_at:=position(first_marker in definition);end_at:=position(last_marker in definition);
 if start_at=0 or end_at<=start_at then raise exception 'Colonization access quota section missing'; end if;
 execute substr(definition,1,start_at-1)||substr(definition,end_at);
end $migration$;
