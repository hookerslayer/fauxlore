do $migration$
declare
  fn text;
  old_fragment text;
  new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.resolve_military_movement(integer,integer)'::regprocedure),chr(13),'');
  old_fragment:='select weather,wind_degrees into weather_value,wind_degrees from fauxlore.province_weather'||E'\n        '||
    'where province_id=province_row.id and year=year_value and turn=turn_value;';
  new_fragment:='select w.weather,w.wind_degrees into weather_value,wind_degrees from fauxlore.province_weather w'||E'\n        '||
    'where w.province_id=province_row.id and w.year=year_value and w.turn=turn_value;';
  if position(old_fragment in fn)=0 then
    if position(new_fragment in fn)>0 then return; end if;
    raise exception 'Could not qualify movement weather columns';
  end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

select pg_notify('pgrst','reload schema');
