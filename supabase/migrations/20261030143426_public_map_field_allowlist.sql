-- New database columns must not become public merely because map_payload uses
-- to_jsonb(provinces). Publish an explicit allowlist after authorization.
do $migration$
declare definition text; old_line text; new_line text;
begin
  definition:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  old_line:='  select coalesce(jsonb_agg(province - ''taxes'' - ''production'' - ''tension'' - ''belonging'' - ''seed_area'' order by (province->>''id'')::integer), ''[]''::jsonb)'||chr(10)||
            '    into provinces from jsonb_array_elements(provinces) province;';
  new_line:='  select coalesce(jsonb_agg((select coalesce(jsonb_object_agg(field.key,field.value),''{}''::jsonb)'||chr(10)||
            '      from jsonb_each(province) field where field.key=any(array['||
            '''id'',''kind'',''name'',''center'',''bbox'',''area'',''population'',''development'',''province_type'',''trade_status'',''control'',''occupation'',''terrain_type'',''has_capital_marker'',''has_city_marker'',''layers'',''occupation_color'',''application_pending'',''race_assimilation_target_id'',''race_assimilation_turns'',''religion_assimilation_target_id'',''religion_assimilation_turns'',''occupation_estate_tax_rates'',''occupation_crime'',''occupation_corruption'']))'||
            ' order by (province->>''id'')::integer),''[]''::jsonb)'||chr(10)||
            '    into provinces from jsonb_array_elements(provinces) province;';
  if position(old_line in definition)=0 then raise exception 'Map province projection changed'; end if;
  execute replace(definition,old_line,new_line);
end
$migration$;
