create or replace function fauxlore.apply_turn_population_and_recruit_growth()
returns trigger language plpgsql security definer set search_path='' as $$
declare state_row record; province_row record; cfg jsonb; indicators jsonb; report_value jsonb; item jsonb;
  province_growth integer; population_growth bigint; recruit_growth bigint; province_changes jsonb;
begin
  select report into report_value from fauxlore.turn_economy_reports where year=new.year and turn=new.turn for update;
  select config into cfg from fauxlore.economy_parameters where singleton;
  for state_row in select state_id,recruits from fauxlore.state_profiles order by state_id loop
    indicators:=fauxlore.state_indicators(state_row.state_id);
    population_growth:=0; province_changes:='[]'::jsonb;
    for province_row in
      select p.id,p.population,race.name race,rv.category_id race_id,relv.category_id religion_id
      from fauxlore.provinces p
      join fauxlore.province_values sv on sv.province_id=p.id and sv.layer='states' and sv.category_id=state_row.state_id
      left join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='races'
      left join fauxlore.map_categories race on race.layer='races' and race.id=rv.category_id
      left join fauxlore.province_values relv on relv.province_id=p.id and relv.layer='religions'
      where p.kind='land' order by p.id
    loop
      if cfg#>>array['raceGrowthModifiers',province_row.race] is null then continue; end if;
      province_growth:=round(province_row.population*.03*(cfg#>>array['raceGrowthModifiers',province_row.race])::numeric
        *(indicators->>'urbanization_growth_multiplier')::numeric
        *(indicators->>'crime_population_growth_multiplier')::numeric
        *fauxlore.group_status_effect(state_row.state_id,'race',province_row.race_id,'population')
        *fauxlore.group_status_effect(state_row.state_id,'religion',province_row.religion_id,'population'),0)::integer;
      if province_growth>0 then
        if province_row.population::bigint+province_growth>2147483647 then raise sqlstate '22003' using message='Прирост населения превышает предел численности провинции'; end if;
        update fauxlore.provinces set population=population+province_growth where id=province_row.id;
        population_growth:=population_growth+province_growth;
        province_changes:=province_changes||jsonb_build_array(jsonb_build_object('province_id',province_row.id,'before',province_row.population,
          'growth',province_growth,'after',province_row.population+province_growth));
      end if;
    end loop;
    recruit_growth:=coalesce((indicators->>'recruit_growth')::bigint,0);
    if recruit_growth>0 then
      if state_row.recruits::bigint+recruit_growth>2147483647 then raise sqlstate '22003' using message='Прирост рекрутов превышает предел резерва государства'; end if;
      update fauxlore.state_profiles set recruits=recruits+recruit_growth where state_id=state_row.state_id;
    end if;
    item:=jsonb_build_object('population_growth_credited',population_growth,'province_population_changes',province_changes,
      'recruits_before',state_row.recruits,'recruit_growth_credited',recruit_growth,'recruits_after',state_row.recruits+recruit_growth);
    select coalesce(jsonb_agg(case when x.value->>'id' ~ '^\d+$' and (x.value->>'id')::integer=state_row.state_id then x.value||item else x.value end order by x.ord),'[]'::jsonb)
      into report_value from jsonb_array_elements(coalesce(report_value,'[]'::jsonb)) with ordinality x(value,ord);
  end loop;
  update fauxlore.turn_economy_reports set report=coalesce(report_value,'[]'::jsonb) where year=new.year and turn=new.turn;
  return new;
end $$;
revoke all on function fauxlore.apply_turn_population_and_recruit_growth() from public,anon,authenticated;
drop trigger if exists zzzzz_apply_turn_population_and_recruit_growth on fauxlore.turn_economy_reports;
create trigger zzzzz_apply_turn_population_and_recruit_growth after insert on fauxlore.turn_economy_reports
for each row execute function fauxlore.apply_turn_population_and_recruit_growth();

-- Include province populations in test-turn conflict detection and rollback.
do $$
declare fn text; marker text;
begin
  fn:=pg_get_functiondef('fauxlore.turn_snapshot_payload()'::regprocedure);
  marker:='''game_calendar'',(select coalesce(jsonb_agg(to_jsonb(x) order by to_jsonb(x)::text),''[]'') from fauxlore.game_calendar x)';
  if position(marker in fn)=0 then raise exception 'Turn snapshot calendar marker missing'; end if;
  fn:=replace(fn,marker,'''province_population'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',id,''population'',population) order by id),''[]'') from fauxlore.provinces),'||chr(10)||'      '||marker);
  execute fn;
end $$;

create or replace function fauxlore.capture_test_turn_province_population()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  new.payload:=coalesce(new.payload,'{}'::jsonb)||jsonb_build_object('province_population',
    (select coalesce(jsonb_agg(jsonb_build_object('id',id,'population',population) order by id),'[]'::jsonb) from fauxlore.provinces));
  return new;
end $$;
revoke all on function fauxlore.capture_test_turn_province_population() from public,anon,authenticated;
drop trigger if exists turn_test_snapshot_capture_provinces on fauxlore.turn_test_snapshot;
create trigger turn_test_snapshot_capture_provinces before insert on fauxlore.turn_test_snapshot
for each row execute function fauxlore.capture_test_turn_province_population();

create or replace function fauxlore.restore_test_turn_province_population()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.after_revision is not null and jsonb_typeof(old.payload->'province_population')='array' then
    lock table fauxlore.provinces in access exclusive mode;
    update fauxlore.provinces p set population=(saved->>'population')::integer
    from jsonb_array_elements(old.payload->'province_population') saved where p.id=(saved->>'id')::integer;
  end if;
  return old;
end $$;
revoke all on function fauxlore.restore_test_turn_province_population() from public,anon,authenticated;
drop trigger if exists turn_test_snapshot_restore_provinces on fauxlore.turn_test_snapshot;
create trigger turn_test_snapshot_restore_provinces before delete on fauxlore.turn_test_snapshot
for each row execute function fauxlore.restore_test_turn_province_population();
notify pgrst,'reload schema';
