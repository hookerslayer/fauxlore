-- Legacy stored/internal province columns are not part of the map contract.
do $migration$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  marker:='  return jsonb_set(jsonb_set(result,''{provinces}'',provinces),''{categories}'',categories);';
  if position(marker in definition)=0 then raise exception 'Map payload return statement changed'; end if;
  definition:=replace(definition,marker,
    '  select coalesce(jsonb_agg(province - ''taxes'' - ''production'' - ''tension'' - ''belonging'' - ''seed_area'' order by (province->>''id'')::integer), ''[]''::jsonb)'||chr(10)||
    '    into provinces from jsonb_array_elements(provinces) province;'||chr(10)||marker);
  execute definition;
end
$migration$;
