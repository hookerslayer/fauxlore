do $migration$
declare
  definition text;
  old_fragment text := 'select weather,wind_degrees into weather_value,wind_degrees from fauxlore.province_weather';
  new_fragment text := 'select weather,province_weather.wind_degrees into weather_value,wind_degrees from fauxlore.province_weather';
begin
  definition:=pg_get_functiondef('fauxlore.military_movement_preview(bigint,jsonb)'::regprocedure);
  if position(old_fragment in definition)=0 then raise exception 'Movement preview wind lookup changed'; end if;
  execute replace(definition,old_fragment,new_fragment);
end
$migration$;
