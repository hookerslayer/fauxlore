-- Add condition- and location-aware modifier resolution, then apply passive
-- development growth with a stored fractional remainder.
create or replace function fauxlore.state_permanent_modifier_total(
  target_state integer, modifier_keys text[], target_province integer default null, target_resource text default null
) returns numeric language plpgsql stable security definer set search_path='' as $function$
declare row_value jsonb; province_row record; local_race text; local_religion text; total numeric:=0;
  scope_value text; condition_value text;
begin
  if target_province is not null then
    select p.province_type,rv.name race_name,rel.name religion_name into province_row
    from fauxlore.provinces p
    left join fauxlore.province_values race_v on race_v.province_id=p.id and race_v.layer='races'
    left join fauxlore.map_categories rv on rv.layer='races' and rv.id=race_v.category_id
    left join fauxlore.province_values religion_v on religion_v.province_id=p.id and religion_v.layer='religions'
    left join fauxlore.map_categories rel on rel.layer='religions' and rel.id=religion_v.category_id
    where p.id=target_province;
    if not found then return 0; end if;
    local_race:=province_row.race_name; local_religion:=province_row.religion_name;
  end if;
  for row_value in select value from jsonb_array_elements(fauxlore.state_permanent_modifiers(target_state)) value
    where value->>'key'=any(modifier_keys)
  loop
    scope_value:=row_value->>'scope'; condition_value:=coalesce(row_value->>'condition','');
    if condition_value='Максимум' then continue; end if;
    if condition_value='Лояльность Знати выше 60%' and coalesce((
      select loyalty from fauxlore.state_group_politics where state_id=target_state and group_type='estate' and group_key='Знать'),0)<=60 then continue; end if;
    if condition_value='Лояльность ключевых сословий выше 60%' and (
      not exists(select 1 from fauxlore.state_group_politics where state_id=target_state and group_type='estate' and status='Ключевое')
      or exists(select 1 from fauxlore.state_group_politics where state_id=target_state and group_type='estate' and status='Ключевое' and loyalty<=60)) then continue; end if;
    if target_province is not null then
      if scope_value='Регионы' and province_row.province_type<>'Регион' then continue; end if;
      if scope_value='Городские и Столичная' and province_row.province_type not in ('Городская','Столичная') then continue; end if;
      if row_value->>'source_kind'='race' and scope_value<>'Государство' and local_race is distinct from row_value->>'source' then continue; end if;
      if row_value->>'source_kind'='religion' and scope_value<>'Государство' and local_religion is distinct from row_value->>'source' then continue; end if;
      if scope_value like '%+ Металлы' and target_resource is distinct from 'Металлы' then continue; end if;
      if scope_value like '%+ Драгоценные металлы' and target_resource is distinct from 'Драгоценные металлы' then continue; end if;
      if scope_value like '%+ Эфемера' and target_resource is distinct from 'Эфемера' then continue; end if;
      if scope_value like '%+ Животноводство' and target_resource is distinct from 'Животноводство' then continue; end if;
      if scope_value like '%+ Лес' and not exists(select 1 from fauxlore.province_values terrain_v
        join fauxlore.map_categories terrain on terrain.layer='terrain_type' and terrain.id=terrain_v.category_id
        where terrain_v.province_id=target_province and terrain.name='Лес') then continue; end if;
    else
      if row_value->>'source_kind' in ('race','religion') and scope_value<>'Государство' then continue; end if;
      if scope_value like 'Провинции %' or scope_value like '% + %' or scope_value in ('Регионы','Городские и Столичная') then continue; end if;
    end if;
    if row_value->>'key'='precious_consumption' and target_resource is not null and target_resource<>'Драгоценные металлы' then continue; end if;
    if row_value->>'key'='other_consumption' and target_resource='Драгоценные металлы' then continue; end if;
    total:=total+coalesce((row_value->>'value')::numeric,0);
  end loop;
  return total;
end $function$;
revoke all on function fauxlore.state_permanent_modifier_total(integer,text[],integer,text) from public,anon,authenticated;

alter table fauxlore.provinces add column if not exists development_fraction numeric(8,2) not null default 0
  check (development_fraction>=0 and development_fraction<1);

create or replace function fauxlore.apply_permanent_development_on_turn()
returns trigger language plpgsql security definer set search_path='' as $function$
declare p record; growth_value numeric; cap_value numeric; accumulated numeric; whole_gain integer;
begin
  if (new.year,new.turn)=(old.year,old.turn) then return new; end if;
  for p in select province.id,owner.category_id state_id,province.province_type,province.development,
      province.development_fraction,resource.name resource_name
    from fauxlore.provinces province
    join fauxlore.province_values owner on owner.province_id=province.id and owner.layer='states'
    left join fauxlore.province_values resource_value on resource_value.province_id=province.id and resource_value.layer='resources'
    left join fauxlore.map_categories resource on resource.layer='resources' and resource.id=resource_value.category_id
    where province.kind='land' order by province.id
  loop
    growth_value:=fauxlore.state_permanent_modifier_total(p.state_id,
      array['development','urban_development','regional_development','forest_development','livestock_development',
        'metal_development','precious_development','ephemera_development'],p.id,p.resource_name);
    if growth_value<=0 then continue; end if;
    cap_value:=null;
    if p.province_type='Регион' then
      select min((m->>'value')::numeric) into cap_value
      from jsonb_array_elements(fauxlore.state_permanent_modifiers(p.state_id)) m
      where m->>'key'='regional_development_cap' and m->>'condition'='Максимум';
    end if;
    select least(coalesce(cap_value,1e12),min((m->>'value')::numeric)) into cap_value
      from jsonb_array_elements(fauxlore.state_permanent_modifiers(p.state_id)) m
      where m->>'key'='development_cap' and m->>'condition'='Максимум';
    growth_value:=least(growth_value,coalesce(cap_value,growth_value));
    accumulated:=p.development_fraction+growth_value;
    whole_gain:=floor(accumulated)::integer;
    update fauxlore.provinces set development=development+whole_gain,
      development_fraction=accumulated-whole_gain where id=p.id;
  end loop;
  return new;
end
$function$;
revoke all on function fauxlore.apply_permanent_development_on_turn() from public,anon,authenticated;
drop trigger if exists apply_permanent_development_on_turn on fauxlore.game_calendar;
create trigger apply_permanent_development_on_turn after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.apply_permanent_development_on_turn();

-- Include the fractional accumulator in test-turn conflict detection and rollback.
do $patch$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure);
  marker:=$m$'province_development',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'development',development) order by id),'[]') from fauxlore.provinces),$m$;
  if position(marker in definition)=0 then raise exception 'Development snapshot marker missing'; end if;
  definition:=replace(definition,marker,marker||E'\n      ''province_development_fraction'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',id,''fraction'',development_fraction) order by id),''[]'') from fauxlore.provinces),');
  execute definition;
end
$patch$;

create or replace function fauxlore.capture_test_turn_development_fraction()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object('province_development_fraction',
    (select coalesce(jsonb_agg(jsonb_build_object('id',id,'fraction',development_fraction) order by id),'[]'::jsonb) from fauxlore.provinces));
  return new;
end
$function$;
revoke all on function fauxlore.capture_test_turn_development_fraction() from public,anon,authenticated;
drop trigger if exists turn_test_snapshot_capture_development_fraction on fauxlore.turn_test_snapshot;
create trigger turn_test_snapshot_capture_development_fraction before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_development_fraction();

create or replace function fauxlore.restore_test_turn_development_fraction()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if old.after_revision is not null and jsonb_typeof(old.payload->'province_development_fraction')='array' then
    update fauxlore.provinces p set development_fraction=(saved->>'fraction')::numeric
      from jsonb_array_elements(old.payload->'province_development_fraction') saved where p.id=(saved->>'id')::integer;
  end if;
  return old;
end
$function$;
revoke all on function fauxlore.restore_test_turn_development_fraction() from public,anon,authenticated;
drop trigger if exists turn_test_snapshot_restore_development_fraction on fauxlore.turn_test_snapshot;
create trigger turn_test_snapshot_restore_development_fraction before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_development_fraction();

notify pgrst,'reload schema';
