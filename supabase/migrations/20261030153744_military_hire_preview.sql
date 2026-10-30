-- Use the exact hire branch for a read-only estimate, including current
-- prerequisites, treasury, recruits, formation and modifier checks.
do $migration$
declare
  definition text;
  guard_marker text := 'elsif action=''hire'' then';
  insert_marker text := 'if formation_key is null then';
begin
  definition:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  if position(guard_marker in definition)=0 or position(insert_marker in definition)=0 then
    raise exception 'Military hire preview insertion points changed';
  end if;
  definition:=replace(definition,guard_marker,'elsif action in (''hire'',''preview_hire'') then');
  definition:=replace(definition,insert_marker,
    'if action=''preview_hire'' then return jsonb_build_object(''cost'',price,''recruits'',amount*unit_row.recruit_cost,
      ''unit_id'',unit_row.id,''quantity'',amount); end if;'||E'\n  '||insert_marker);
  execute definition;
end
$migration$;
