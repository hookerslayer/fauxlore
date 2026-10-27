-- Province-level racial and religious assimilation toward each state's official groups.
alter table fauxlore.provinces
  add column if not exists race_assimilation_turns integer
    check (race_assimilation_turns is null or race_assimilation_turns between 1 and 300),
  add column if not exists race_assimilation_target_id integer,
  add column if not exists religion_assimilation_turns integer
    check (religion_assimilation_turns is null or religion_assimilation_turns between 1 and 300),
  add column if not exists religion_assimilation_target_id integer;

create or replace function fauxlore.assimilation_duration(status_value text)
returns integer language sql immutable set search_path='' as $function$
  select case status_value
    when 'Признание' then 60
    when 'Ассимиляция' then 10
    when 'Истребление' then 5
    else 30
  end
$function$;
revoke all on function fauxlore.assimilation_duration(text) from public,anon,authenticated;

create or replace function fauxlore.reset_province_assimilation_on_group_change()
returns trigger language plpgsql security definer set search_path='' as $function$
declare target_id integer;
begin
  if tg_op='UPDATE' and new.category_id is not distinct from old.category_id then return new; end if;
  target_id:=case when tg_op='DELETE' then old.province_id else new.province_id end;
  if tg_op='DELETE' then
    if old.layer='races' then
      update fauxlore.provinces set race_assimilation_turns=null,race_assimilation_target_id=null where id=target_id;
    elsif old.layer='religions' then
      update fauxlore.provinces set religion_assimilation_turns=null,religion_assimilation_target_id=null where id=target_id;
    elsif old.layer='states' then
      update fauxlore.provinces set race_assimilation_turns=null,race_assimilation_target_id=null,
        religion_assimilation_turns=null,religion_assimilation_target_id=null where id=target_id;
    end if;
    return old;
  end if;
  if new.layer='races' then
    update fauxlore.provinces set race_assimilation_turns=null,race_assimilation_target_id=null where id=target_id;
  elsif new.layer='religions' then
    update fauxlore.provinces set religion_assimilation_turns=null,religion_assimilation_target_id=null where id=target_id;
  elsif new.layer='states' then
    update fauxlore.provinces set race_assimilation_turns=null,race_assimilation_target_id=null,
      religion_assimilation_turns=null,religion_assimilation_target_id=null where id=target_id;
  end if;
  return new;
end
$function$;
revoke all on function fauxlore.reset_province_assimilation_on_group_change() from public,anon,authenticated;
create trigger reset_province_assimilation_on_group_change
  after insert or update or delete on fauxlore.province_values
  for each row execute function fauxlore.reset_province_assimilation_on_group_change();

create or replace function fauxlore.reset_state_assimilation_on_official_change()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if new.official_race_id is distinct from old.official_race_id then
    update fauxlore.provinces p set race_assimilation_turns=null,race_assimilation_target_id=null
    where exists(select 1 from fauxlore.province_values owner
      where owner.province_id=p.id and owner.layer='states' and owner.category_id=new.state_id);
  end if;
  if new.official_religion_id is distinct from old.official_religion_id then
    update fauxlore.provinces p set religion_assimilation_turns=null,religion_assimilation_target_id=null
    where exists(select 1 from fauxlore.province_values owner
      where owner.province_id=p.id and owner.layer='states' and owner.category_id=new.state_id);
  end if;
  return new;
end
$function$;
revoke all on function fauxlore.reset_state_assimilation_on_official_change() from public,anon,authenticated;
create trigger reset_state_assimilation_on_official_change
  after update of official_race_id,official_religion_id on fauxlore.state_profiles
  for each row execute function fauxlore.reset_state_assimilation_on_official_change();

create or replace function fauxlore.process_province_assimilation()
returns integer language plpgsql security definer set search_path='' as $function$
declare province_row record; group_kind text; source_id integer; target_id integer;
  status_value text; remaining integer; stored_target integer; changed integer:=0; touched boolean:=false;
begin
  for province_row in
    select p.id,p.occupation,owner.category_id state_id,sp.official_race_id,sp.official_religion_id,
      race.category_id race_id,religion.category_id religion_id,
      p.race_assimilation_turns,p.race_assimilation_target_id,
      p.religion_assimilation_turns,p.religion_assimilation_target_id
    from fauxlore.provinces p
    join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states'
    join fauxlore.state_profiles sp on sp.state_id=owner.category_id
    left join fauxlore.province_values race on race.province_id=p.id and race.layer='races'
    left join fauxlore.province_values religion on religion.province_id=p.id and religion.layer='religions'
    where p.kind='land'
    order by p.id
    for update of p
  loop
    foreach group_kind in array array['race','religion'] loop
      if group_kind='race' then
        source_id:=province_row.race_id;target_id:=province_row.official_race_id;
        remaining:=province_row.race_assimilation_turns;stored_target:=province_row.race_assimilation_target_id;
      else
        source_id:=province_row.religion_id;target_id:=province_row.official_religion_id;
        remaining:=province_row.religion_assimilation_turns;stored_target:=province_row.religion_assimilation_target_id;
      end if;
      if source_id is null or target_id is null then continue; end if;
      if source_id=target_id then
        if remaining is not null or stored_target is not null then
          if group_kind='race' then
            update fauxlore.provinces set race_assimilation_turns=null,race_assimilation_target_id=null where id=province_row.id;
          else
            update fauxlore.provinces set religion_assimilation_turns=null,religion_assimilation_target_id=null where id=province_row.id;
          end if;
          touched:=true;
        end if;
        continue;
      end if;
      -- Occupation suspends the owner's assimilation rather than advancing it.
      if province_row.occupation is not null then continue; end if;
      if remaining is null or stored_target is distinct from target_id then
        select coalesce(gp.status,'Невмешательство') into status_value
        from fauxlore.state_profiles sp
        left join fauxlore.state_group_politics gp on gp.state_id=sp.state_id
          and gp.group_type=group_kind and gp.group_key=source_id::text
        where sp.state_id=province_row.state_id;
        remaining:=fauxlore.assimilation_duration(coalesce(status_value,'Невмешательство'));
      end if;
      if remaining<=1 then
        update fauxlore.province_values set category_id=target_id
        where province_id=province_row.id and layer=case group_kind when 'race' then 'races' else 'religions' end
          and category_id=source_id;
        if found then changed:=changed+1; end if;
      elsif group_kind='race' then
        update fauxlore.provinces set race_assimilation_turns=remaining-1,
          race_assimilation_target_id=target_id where id=province_row.id;
        touched:=true;
      else
        update fauxlore.provinces set religion_assimilation_turns=remaining-1,
          religion_assimilation_target_id=target_id where id=province_row.id;
        touched:=true;
      end if;
    end loop;
  end loop;
  if touched or changed>0 then
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  end if;
  return changed;
end
$function$;
revoke all on function fauxlore.process_province_assimilation() from public,anon,authenticated;

create or replace function fauxlore.advance_province_assimilation()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if (new.year,new.turn) is not distinct from (old.year,old.turn) then return new; end if;
  perform fauxlore.process_province_assimilation();
  return new;
end
$function$;
revoke all on function fauxlore.advance_province_assimilation() from public,anon,authenticated;
create trigger zzzzzz_advance_province_assimilation after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.advance_province_assimilation();

-- Administrator can set an explicit timer; zero or null restores the automatic status duration.
create or replace function fauxlore.set_province_assimilation(province_id integer,payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
#variable_conflict use_variable
declare actor fauxlore.accounts; province_row fauxlore.provinces; state_id integer;
  official_race integer; official_religion integer; race_id integer; religion_id integer;
  race_turns integer; religion_turns integer;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' then raise sqlstate '42501' using message='Изменять срок ассимиляции может только администратор'; end if;
  if jsonb_typeof(payload) is distinct from 'object' or payload- array['race_turns','religion_turns']<>'{}'::jsonb
    or not(payload ? 'race_turns') or not(payload ? 'religion_turns') then
    raise sqlstate '22023' using message='Укажите сроки ассимиляции расы и религии'; end if;
  select * into province_row from fauxlore.provinces where id=province_id and kind='land' for update;
  if not found then raise sqlstate 'P0002' using message='Сухопутная провинция не найдена'; end if;
  select owner.category_id,sp.official_race_id,sp.official_religion_id,race.category_id,religion.category_id
    into state_id,official_race,official_religion,race_id,religion_id
  from fauxlore.province_values owner join fauxlore.state_profiles sp on sp.state_id=owner.category_id
  left join fauxlore.province_values race on race.province_id=province_id and race.layer='races'
  left join fauxlore.province_values religion on religion.province_id=province_id and religion.layer='religions'
  where owner.province_id=province_id and owner.layer='states';
  if not found then raise sqlstate '22023' using message='Провинция должна принадлежать государству'; end if;
  if jsonb_typeof(payload->'race_turns') not in ('number','null') or jsonb_typeof(payload->'religion_turns') not in ('number','null') then
    raise sqlstate '22023' using message='Срок должен быть целым числом от 0 до 300'; end if;
  race_turns:=case when payload->'race_turns'='null'::jsonb then 0 else (payload->>'race_turns')::integer end;
  religion_turns:=case when payload->'religion_turns'='null'::jsonb then 0 else (payload->>'religion_turns')::integer end;
  if race_turns not between 0 and 300 or religion_turns not between 0 and 300 then
    raise sqlstate '22023' using message='Срок должен быть целым числом от 0 до 300'; end if;
  if race_turns>0 and (race_id is null or race_id=official_race) then raise sqlstate '22023' using message='В этой провинции нет расы для ассимиляции'; end if;
  if religion_turns>0 and (religion_id is null or religion_id=official_religion) then raise sqlstate '22023' using message='В этой провинции нет религии для ассимиляции'; end if;
  update fauxlore.provinces set
    race_assimilation_turns=nullif(race_turns,0),race_assimilation_target_id=case when race_turns>0 then official_race else null end,
    religion_assimilation_turns=nullif(religion_turns,0),religion_assimilation_target_id=case when religion_turns>0 then official_religion else null end
  where id=province_id returning * into province_row;
  return to_jsonb(province_row);
end
$function$;
revoke all on function fauxlore.set_province_assimilation(integer,jsonb) from public,anon,authenticated;

-- Preserve province group assignments and countdowns in the reversible test-turn checkpoint.
do $$
declare definition text; marker text;
begin
  definition:=pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure);
  marker:='''game_calendar'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.game_calendar x)';
  if position(marker in definition)=0 then raise exception 'Turn snapshot calendar marker missing for assimilation'; end if;
  definition:=replace(definition,marker,
    '''province_race_religion_values'',(select coalesce(jsonb_agg(jsonb_build_object(''province_id'',province_id,''layer'',layer,''category_id'',category_id) order by province_id,layer),''[]'') from fauxlore.province_values where layer in (''races'',''religions'')),'||chr(10)||
    '    ''province_assimilation_state'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',id,''race_assimilation_turns'',race_assimilation_turns,''race_assimilation_target_id'',race_assimilation_target_id,''religion_assimilation_turns'',religion_assimilation_turns,''religion_assimilation_target_id'',religion_assimilation_target_id) order by id),''[]'') from fauxlore.provinces),'||chr(10)||'    '||marker);
  execute definition;
end $$;

create or replace function fauxlore.capture_test_turn_assimilation()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object(
    'province_race_religion_values',(select coalesce(jsonb_agg(jsonb_build_object('province_id',province_id,'layer',layer,'category_id',category_id) order by province_id,layer),'[]') from fauxlore.province_values where layer in ('races','religions')),
    'province_assimilation_state',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'race_assimilation_turns',race_assimilation_turns,'race_assimilation_target_id',race_assimilation_target_id,'religion_assimilation_turns',religion_assimilation_turns,'religion_assimilation_target_id',religion_assimilation_target_id) order by id),'[]') from fauxlore.provinces));
  return new;
end
$function$;
revoke all on function fauxlore.capture_test_turn_assimilation() from public,anon,authenticated;
create trigger turn_test_snapshot_capture_assimilation before insert on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.capture_test_turn_assimilation();

create or replace function fauxlore.restore_test_turn_assimilation()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if old.after_revision is null or jsonb_typeof(old.payload->'province_race_religion_values')<>'array'
    or jsonb_typeof(old.payload->'province_assimilation_state')<>'array' then return old; end if;
  lock table fauxlore.provinces,fauxlore.province_values in access exclusive mode;
  delete from fauxlore.province_values where layer in ('races','religions');
  insert into fauxlore.province_values(province_id,layer,category_id)
    select (item->>'province_id')::integer,item->>'layer',(item->>'category_id')::integer
    from jsonb_array_elements(old.payload->'province_race_religion_values') item;
  update fauxlore.provinces p set race_assimilation_turns=(saved->>'race_assimilation_turns')::integer,
    race_assimilation_target_id=(saved->>'race_assimilation_target_id')::integer,
    religion_assimilation_turns=(saved->>'religion_assimilation_turns')::integer,
    religion_assimilation_target_id=(saved->>'religion_assimilation_target_id')::integer
  from jsonb_array_elements(old.payload->'province_assimilation_state') saved where p.id=(saved->>'id')::integer;
  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  return old;
end
$function$;
revoke all on function fauxlore.restore_test_turn_assimilation() from public,anon,authenticated;
create trigger turn_test_snapshot_restore_assimilation before delete on fauxlore.turn_test_snapshot
  for each row execute function fauxlore.restore_test_turn_assimilation();

do $$
declare definition text; marker text; replacement text;
begin
  definition:=replace(pg_get_functiondef('fauxlore.api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  marker:='elsif path~''^admin/provinces/\d+$'' and method=''PATCH'' then'||chr(10)||
    '    result:=fauxlore.edit_province(split_part(path,''/'',3)::integer,body);';
  replacement:='elsif path~''^admin/provinces/\d+/assimilation$'' and method=''PATCH'' then'||chr(10)||
    '    result:=fauxlore.set_province_assimilation(split_part(path,''/'',3)::integer,body);'||chr(10)||'  '||marker;
  if position(marker in definition)=0 then raise exception 'Admin province route marker missing for assimilation'; end if;
  execute replace(definition,marker,replacement);
end $$;

notify pgrst,'reload schema';
