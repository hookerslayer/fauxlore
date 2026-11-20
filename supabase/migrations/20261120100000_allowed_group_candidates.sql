-- Кандидаты в правители и местные супруги выбираются только из тех рас и
-- религий, которые присутствуют в государстве и имеют статус «Официальная»
-- или «Признание». Раньше при смерти правителя с шансом 30% выбиралась любая
-- раса карты (так в дварфском государстве появился эльф), а поиск супруга
-- брал религию любой провинции.

create or replace function fauxlore.state_allowed_group_ids(target_state integer, group_layer text)
returns integer[] language sql stable security definer set search_path='' as $fn$
  select coalesce(array_agg(distinct category_id),'{}'::integer[])
  from (
    select rv.category_id
    from fauxlore.province_values sv
    join fauxlore.provinces p on p.id=sv.province_id and p.kind='land'
    join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer=group_layer
    where sv.layer='states' and sv.category_id=target_state
      and exists(select 1 from fauxlore.state_group_politics g
        where g.state_id=target_state
          and g.group_type=case group_layer when 'races' then 'race' else 'religion' end
          and g.group_key=rv.category_id::text
          and g.status in ('Официальная','Признание'))
    union all
    select sp.official_race_id from fauxlore.state_profiles sp
      where sp.state_id=target_state and group_layer='races'
    union all
    select sp.official_religion_id from fauxlore.state_profiles sp
      where sp.state_id=target_state and group_layer='religions'
  ) groups
$fn$;
revoke all on function fauxlore.state_allowed_group_ids(integer,text) from public,anon,authenticated;

create or replace function fauxlore.allowed_candidate_race(target_state integer,official_race integer)
returns integer language plpgsql volatile security definer set search_path='' as $fn$
declare ids integer[];
begin
  ids:=fauxlore.state_allowed_group_ids(target_state,'races');
  if cardinality(ids)=0 then return official_race; end if;
  if official_race=any(ids) and random()<.7 then return official_race; end if;
  return ids[1+floor(random()*cardinality(ids))::integer];
end $fn$;
revoke all on function fauxlore.allowed_candidate_race(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.allowed_candidate_religion(target_state integer,official_religion integer)
returns integer language plpgsql volatile security definer set search_path='' as $fn$
declare ids integer[];
begin
  ids:=fauxlore.state_allowed_group_ids(target_state,'religions');
  if cardinality(ids)=0 then return official_religion; end if;
  if official_religion=any(ids) and random()<.7 then return official_religion; end if;
  return ids[1+floor(random()*cardinality(ids))::integer];
end $fn$;
revoke all on function fauxlore.allowed_candidate_religion(integer,integer) from public,anon,authenticated;

-- Смерть правителя: регент и кандидаты выборов.
do $migration$
declare definition text;
  regent_races text:=$m$        if random()<.7 then race_value:=sp.official_race_id; else select id into race_value from fauxlore.map_categories where layer='races' order by random() limit 1; end if;
        if random()<.7 then religion_value:=sp.official_religion_id; else select id into religion_value from fauxlore.map_categories where layer='religions' order by random() limit 1; end if;$m$;
  regent_new text:=$m$        race_value:=fauxlore.allowed_candidate_race(old.state_id,sp.official_race_id);
        religion_value:=fauxlore.allowed_candidate_religion(old.state_id,sp.official_religion_id);$m$;
  election_old text:=$m$    if authority_value='Клир' then religion_value:=sp.official_religion_id;
    elsif random()<.7 then religion_value:=sp.official_religion_id;
    else select id into religion_value from fauxlore.map_categories where layer='religions' order by random() limit 1; end if;
    if random()<.7 then race_value:=sp.official_race_id; else select id into race_value from fauxlore.map_categories where layer='races' order by random() limit 1; end if;$m$;
  election_new text:=$m$    if authority_value='Клир' then religion_value:=sp.official_religion_id;
    else religion_value:=fauxlore.allowed_candidate_religion(old.state_id,sp.official_religion_id); end if;
    race_value:=fauxlore.allowed_candidate_race(old.state_id,sp.official_race_id);$m$;
begin
  definition:=pg_get_functiondef('fauxlore.start_ruler_succession()'::regprocedure);
  if position('allowed_candidate_race' in definition)=0 then
    if position(regent_races in definition)=0 then raise exception 'Regent race generation changed'; end if;
    definition:=replace(definition,regent_races,regent_new);
    if position(election_old in definition)=0 then raise exception 'Election race generation changed'; end if;
    definition:=replace(definition,election_old,election_new);
    execute definition;
  end if;
end $migration$;

-- Плановые перевыборы по сроку полномочий.
do $migration$
declare definition text;
  old_part text:=$m$        if random()<.7 then race_value:=sp.official_race_id; else select rv.category_id into race_value from fauxlore.province_values sv join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer='races' where sv.layer='states' and sv.category_id=sp.state_id group by rv.category_id order by random() limit 1; end if;
        if sp.principles->>'authority'='Клир' or random()<.7 then religion_value:=sp.official_religion_id; else select rv.category_id into religion_value from fauxlore.province_values sv join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer='religions' where sv.layer='states' and sv.category_id=sp.state_id group by rv.category_id order by random() limit 1; end if;$m$;
  new_part text:=$m$        race_value:=fauxlore.allowed_candidate_race(sp.state_id,sp.official_race_id);
        if sp.principles->>'authority'='Клир' then religion_value:=sp.official_religion_id;
        else religion_value:=fauxlore.allowed_candidate_religion(sp.state_id,sp.official_religion_id); end if;$m$;
begin
  definition:=pg_get_functiondef('fauxlore.succession_annual_tick()'::regprocedure);
  if position('allowed_candidate_race' in definition)=0 then
    if position(old_part in definition)=0 then raise exception 'Term election race generation changed'; end if;
    execute replace(definition,old_part,new_part);
  end if;
end $migration$;

-- Местный брак: раса из разрешённых и присутствующих, религия — тоже.
do $migration$
declare definition text;
  race_old text:=$m$      race_values:=array(select id from fauxlore.map_categories where layer='races' and name=any(
        case ruler_race_name when 'Люди' then array['Люди','Эльфы','Полуэльфы'] when 'Эльфы' then array['Люди','Эльфы','Полуэльфы']
          when 'Полуэльфы' then array['Люди','Эльфы','Полуэльфы'] when 'Дварфы' then array['Дварфы'] when 'Зверолюди' then array['Зверолюди'] else array[ruler_race_name] end));$m$;
  race_new text:=$m$      race_values:=array(select id from fauxlore.map_categories where layer='races'
        and id=any(fauxlore.state_allowed_group_ids(state_value,'races')) and name=any(
        case ruler_race_name when 'Люди' then array['Люди','Эльфы','Полуэльфы'] when 'Эльфы' then array['Люди','Эльфы','Полуэльфы']
          when 'Полуэльфы' then array['Люди','Эльфы','Полуэльфы'] when 'Дварфы' then array['Дварфы'] when 'Зверолюди' then array['Зверолюди'] else array[ruler_race_name] end));
      if cardinality(race_values)=0 then race_values:=fauxlore.state_allowed_group_ids(state_value,'races'); end if;$m$;
  pick_old text:=$m$        select race.category_id,faith.category_id into candidate_race,candidate_religion
        from fauxlore.province_values owner
        join fauxlore.provinces p on p.id=owner.province_id and p.kind='land' and p.population>0
        join fauxlore.province_values race on race.province_id=p.id and race.layer='races' and race.category_id=any(race_values)
        join fauxlore.province_values faith on faith.province_id=p.id and faith.layer='religions'
        where owner.layer='states' and owner.category_id=state_value
        order by -ln(greatest(random(),0.000000000001))/p.population limit 1;
        if not found then raise sqlstate '22023' using message='Нет населённой провинции с совместимой расой и указанной религией для поиска местного супруга'; end if;$m$;
  pick_new text:=$m$        select race.category_id into candidate_race
        from fauxlore.province_values owner
        join fauxlore.provinces p on p.id=owner.province_id and p.kind='land' and p.population>0
        join fauxlore.province_values race on race.province_id=p.id and race.layer='races' and race.category_id=any(race_values)
        where owner.layer='states' and owner.category_id=state_value
        order by -ln(greatest(random(),0.000000000001))/p.population limit 1;
        if not found then raise sqlstate '22023' using message='Нет населённой провинции с подходящей расой для поиска местного супруга'; end if;
        select faith.category_id into candidate_religion
        from fauxlore.province_values owner
        join fauxlore.provinces p on p.id=owner.province_id and p.kind='land' and p.population>0
        join fauxlore.province_values faith on faith.province_id=p.id and faith.layer='religions'
          and faith.category_id=any(fauxlore.state_allowed_group_ids(state_value,'religions'))
        where owner.layer='states' and owner.category_id=state_value
        order by -ln(greatest(random(),0.000000000001))/p.population limit 1;
        if not found then candidate_religion:=state_row.official_religion_id; end if;$m$;
begin
  definition:=pg_get_functiondef('fauxlore.character_lifecycle_api(text,text,jsonb,uuid)'::regprocedure);
  if position('state_allowed_group_ids' in definition)=0 then
    if position(race_old in definition)=0 then raise exception 'Marriage race pool changed'; end if;
    definition:=replace(definition,race_old,race_new);
    if position(pick_old in definition)=0 then raise exception 'Marriage candidate sampling changed'; end if;
    definition:=replace(definition,pick_old,pick_new);
    execute definition;
  end if;
end $migration$;

notify pgrst,'reload schema';
