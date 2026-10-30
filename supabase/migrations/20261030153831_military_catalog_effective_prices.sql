-- Publish ready-to-display unit prices so the client no longer applies cost
-- modifiers itself. The hire preview still validates quantity and resources.
do $migration$
declare
  definition text;
  marker text := '''upkeep_factor'',fauxlore.military_unit_cost_factor(sid,u.id,''upkeep'')';
begin
  definition:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  if position(marker in definition)=0 then raise exception 'Military catalog cost fields changed'; end if;
  definition:=replace(definition,marker,marker||
    ',''hire_price'',floor(u.hire_cost*fauxlore.military_unit_cost_factor(sid,u.id,''hire''))'||
    ',''upkeep_price'',floor(u.upkeep*fauxlore.military_unit_cost_factor(sid,u.id,''upkeep''))');
  execute definition;
end
$migration$;
