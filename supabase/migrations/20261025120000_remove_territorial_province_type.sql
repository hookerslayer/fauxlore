-- A newly colonized province is a Region unless it has a city/capital marker.
do $migration$
declare fn text; old_fragment text;
begin
  select pg_get_functiondef(p.oid) into fn from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='fauxlore' and p.proname='edit_province'
      and pg_get_function_identity_arguments(p.oid)='province_id integer, changes jsonb';
  old_fragment:='elsif p.province_type<>''Территориальная'' then p.province_type:=''Регион''; end if;';
  if fn is null or position(old_fragment in fn)=0 then
    raise exception 'Unexpected edit_province implementation; migration stopped';
  end if;
  execute replace(fn,old_fragment,'else p.province_type:=''Регион''; end if;');

  select pg_get_functiondef(p.oid) into fn from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='fauxlore' and p.proname='sync_province_type_from_markers'
      and pg_get_function_identity_arguments(p.oid)='';
  old_fragment:='when province_type=''Территориальная'' then ''Территориальная'' else ''Регион''';
  if fn is null or position(old_fragment in fn)=0 then
    raise exception 'Unexpected marker trigger implementation; migration stopped';
  end if;
  execute replace(fn,old_fragment,'else ''Регион''');
end $migration$;

update fauxlore.provinces set province_type='Регион'
where province_type='Территориальная';
alter table fauxlore.provinces drop constraint provinces_province_type_check;
alter table fauxlore.provinces add constraint provinces_province_type_check
  check (province_type in ('Регион','Городская','Столичная'));

update fauxlore.economy_parameters set config=
  jsonb_set(
    jsonb_set(
      jsonb_set(config,'{provinceModifiers}',coalesce(config->'provinceModifiers','{}'::jsonb)-'Территориальная'),
      '{recruitGrowthModifiers}',coalesce(config->'recruitGrowthModifiers','{}'::jsonb)-'Территориальная'),
    '{recruitLimitModifiers}',coalesce(config->'recruitLimitModifiers','{}'::jsonb)-'Территориальная')
where singleton=true;
