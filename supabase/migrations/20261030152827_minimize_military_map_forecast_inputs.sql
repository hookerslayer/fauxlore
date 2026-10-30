-- Movement conditions and the game calendar were only used by the browser's
-- movement calculator. The authoritative preview now reads them on the server.
do $migration$
declare
  definition text;
  start_at integer;
  finish_at integer;
begin
  definition:=pg_get_functiondef('public.military_map_api()'::regprocedure);
  start_at:=position('''calendar'',(select jsonb_build_object(''year'',year,''turn'',turn)' in definition);
  finish_at:=position(',''fog_of_war'',not all_visible' in definition);
  if start_at=0 or finish_at<=start_at then raise exception 'Military map forecast fields changed'; end if;
  definition:=left(definition,start_at-1)||substr(definition,finish_at+1);
  execute definition;
end
$migration$;
