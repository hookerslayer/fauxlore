do $migration$
declare
  definition text;
  marker text := 'limit 30 offset greatest';
  replacement text := 'limit greatest(1,least(1000,coalesce((payload->>''limit'')::integer,5))) offset greatest';
begin
  definition := pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  if position(marker in definition) = 0 then
    raise exception 'Wall pagination marker missing';
  end if;
  execute replace(definition, marker, replacement);
end $migration$;
