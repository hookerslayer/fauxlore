-- Retire the obsolete custom combat-stat editor before removing its columns.
do $migration$
declare definition text; revised text;
begin
  definition:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
  revised:=regexp_replace(definition, 'if action=''admin_unit'' then[\s\S]*?elsif action=''admin_mercenary'' then',
    'if action=''admin_unit'' then raise sqlstate ''22023'' using message=''Создание боевых характеристик больше недоступно''; elsif action=''admin_mercenary'' then');
  if revised=definition then raise exception 'Retired unit editor not found'; end if;
  execute revised;
end $migration$;
alter table fauxlore.military_unit_catalog
  drop column health, drop column damage, drop column charge_damage,
  drop column armor, drop column initiative, drop column power;
notify pgrst,'reload schema';
