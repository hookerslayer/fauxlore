-- Give the interface ready-to-display upkeep per part and per formation unit.
do $migration$
declare
  definition text;
  marker text := '''upkeep'',u.upkeep,''capacity'',u.capacity';
begin
  definition:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  if position(marker in definition)=0 then raise exception 'Formation units snapshot changed'; end if;
  definition:=replace(definition,marker,marker||
    ',''unit_upkeep'',floor(u.upkeep*fauxlore.military_unit_cost_factor(sid,u.id,''upkeep''))'||
    ',''total_upkeep'',case when f.kind=''regular'' then floor(u.upkeep*'||
    'fauxlore.military_unit_cost_factor(sid,u.id,''upkeep'')*greatest(0,fu.quantity-'||
    'case when u.name=''Копейщик'' then least(fu.quantity,coalesce(f.free_upkeep_quantity,0)) else 0 end))'||
    ' when f.kind=''militia'' then fu.quantity*u.upkeep else 0 end');
  execute definition;
end
$migration$;
