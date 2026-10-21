create table if not exists fauxlore.state_birth_events (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  year integer not null,
  turn integer not null,
  father_id bigint not null references fauxlore.state_characters(id),
  mother_id bigint not null references fauxlore.state_characters(id),
  children jsonb not null check(jsonb_typeof(children)='array' and jsonb_array_length(children) between 1 and 3),
  named_at timestamptz,
  created_at timestamptz not null default now(),
  unique(state_id,year)
);
create index if not exists state_birth_events_pending_idx on fauxlore.state_birth_events(state_id,year) where named_at is null;

create table if not exists fauxlore.state_marriage_candidates (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  created_turn integer not null,
  name text not null,
  surname text not null default '',
  gender text not null check(gender in ('Мужской','Женский')),
  age smallint not null check(age between 18 and 59),
  race_id integer not null,
  religion_id integer not null,
  supported_by text[] not null default '{}',
  selected_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists state_marriage_candidates_current_idx on fauxlore.state_marriage_candidates(state_id,created_turn) where selected_at is null;
alter table fauxlore.state_birth_events enable row level security;
alter table fauxlore.state_marriage_candidates enable row level security;
revoke all on fauxlore.state_birth_events,fauxlore.state_marriage_candidates from public,anon,authenticated;

create or replace function fauxlore.process_annual_births()
returns trigger language plpgsql security definer set search_path='' as $$
declare couple record; child_count integer; child_race integer; children_value jsonb; mother_death_chance numeric; mother_died boolean;
  child_index integer; is_lawful boolean; father_race text; mother_race text; authority_name text; birth_roll numeric;
begin
  if new.year=old.year then return new; end if;
  for couple in
    select sp.state_id,sp.principles,sp.official_race_id,sp.official_religion_id,
      ruler.id ruler_id,ruler.name ruler_name,ruler.surname ruler_surname,ruler.gender ruler_gender,ruler.age ruler_age,
      ruler.race_id ruler_race_id,ruler.religion_id ruler_religion_id,
      spouse.id spouse_id,spouse.gender spouse_gender,spouse.age spouse_age,spouse.race_id spouse_race_id,
      spouse.religion_id spouse_religion_id,
      case when m.character_a_id=ruler.id then m.lawful_for_a else m.lawful_for_b end lawful_for_ruler,
      coalesce(ruler_race.name,'') ruler_race,coalesce(spouse_race.name,'') spouse_race
    from fauxlore.state_profiles sp
    join fauxlore.state_characters ruler on ruler.state_id=sp.state_id and ruler.is_current_ruler and ruler.alive
    join fauxlore.state_marriages m on m.ended_at_turn is null and ruler.id in (m.character_a_id,m.character_b_id)
    join fauxlore.state_characters spouse on spouse.id=case when m.character_a_id=ruler.id then m.character_b_id else m.character_a_id end and spouse.alive
    left join fauxlore.map_categories ruler_race on ruler_race.layer='races' and ruler_race.id=ruler.race_id
    left join fauxlore.map_categories spouse_race on spouse_race.layer='races' and spouse_race.id=spouse.race_id
    where (ruler.gender='Мужской' and ruler.age<60 and spouse.gender='Женский' and spouse.age<45)
       or (ruler.gender='Женский' and ruler.age<45 and spouse.gender='Мужской' and spouse.age<60)
  loop
    father_race:=case when couple.ruler_gender='Мужской' then couple.ruler_race else couple.spouse_race end;
    mother_race:=case when couple.ruler_gender='Женский' then couple.ruler_race else couple.spouse_race end;
    if father_race=mother_race and father_race in ('Люди','Эльфы','Дварфы','Зверолюди') then
      child_race:=case when couple.ruler_gender='Мужской' then couple.ruler_race_id else couple.spouse_race_id end;
    elsif father_race in ('Люди','Эльфы','Полуэльфы') and mother_race in ('Люди','Эльфы','Полуэльфы') then
      child_race:=case when father_race='Люди' and mother_race='Люди' then (select id from fauxlore.map_categories where layer='races' and name='Люди' limit 1)
        when father_race='Эльфы' and mother_race='Эльфы' then (select id from fauxlore.map_categories where layer='races' and name='Эльфы' limit 1)
        else (select id from fauxlore.map_categories where layer='races' and name='Полуэльфы' limit 1) end;
    else continue;
    end if;
    if child_race is null or random()>=.25 then continue; end if;
    birth_roll:=random();
    child_count:=case when birth_roll<.94 then 1 when birth_roll<.99 then 2 else 3 end;
    authority_name:=coalesce(couple.principles->>'authority','');
    is_lawful:=authority_name='Династия' and couple.lawful_for_ruler;
    children_value:='[]'::jsonb;
    for child_index in 1..child_count loop
      children_value:=children_value||jsonb_build_array(jsonb_build_object(
        'gender',case when random()<.5 then 'Мужской' else 'Женский' end,
        'race_id',child_race,
        'religion_id',case when random()<.5 then case when couple.ruler_gender='Мужской' then couple.ruler_religion_id else couple.spouse_religion_id end
          else case when couple.ruler_gender='Женский' then couple.ruler_religion_id else couple.spouse_religion_id end end,
        'legitimacy',case when authority_name='Династия' then case when is_lawful then 'Законный' else 'Незаконный' end else 'Неприменимо' end));
    end loop;
    mother_died:=false;
    mother_death_chance:=case when (case when couple.ruler_gender='Женский' then couple.ruler_age else couple.spouse_age end)<35 then .01
      when (case when couple.ruler_gender='Женский' then couple.ruler_age else couple.spouse_age end)<40 then .03 else .07 end
      +case when child_count=2 then .02 when child_count=3 then .04 else 0 end;
    mother_death_chance:=least(.10,mother_death_chance);
    mother_died:=random()<mother_death_chance;
    insert into fauxlore.state_birth_events(state_id,year,turn,father_id,mother_id,children)
    values(couple.state_id,new.year,new.turn,
      case when couple.ruler_gender='Мужской' then couple.ruler_id else couple.spouse_id end,
      case when couple.ruler_gender='Женский' then couple.ruler_id else couple.spouse_id end,children_value);
    if mother_died then
      update fauxlore.state_characters set alive=false,died_at_turn=new.turn,is_current_ruler=false
      where id=case when couple.ruler_gender='Женский' then couple.ruler_id else couple.spouse_id end;
    end if;
    insert into fauxlore.notifications(account_id,kind,title,message)
    select recipients.account_id,'birth','Рождение в семье правителя',
      'В семье государства родилось детей: '||child_count||'. Откройте вкладку «Власть и династия», чтобы указать имена.'||
      case when mother_died then ' Мать детей умерла при родах.' else '' end
    from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=couple.state_id
      union select ac.id from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=couple.state_id)) recipients;
  end loop;
  return new;
end $$;
revoke all on function fauxlore.process_annual_births() from public,anon,authenticated;
drop trigger if exists game_calendar_process_births on fauxlore.game_calendar;
create trigger game_calendar_process_births after update of year on fauxlore.game_calendar
for each row when (new.year is distinct from old.year) execute function fauxlore.process_annual_births();

create or replace function fauxlore.character_lifecycle_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_value integer; birth_value bigint; candidate_value bigint; state_row fauxlore.state_profiles;
  ruler fauxlore.state_characters; event_row fauxlore.state_birth_events; calendar_row fauxlore.game_calendar;
  result jsonb; fingerprint text; previous fauxlore.operations; names_value jsonb; child jsonb; candidate fauxlore.state_marriage_candidates; spouse_row fauxlore.state_characters;
  gender_value text; race_values integer[]; candidate_names text[]; candidate_surnames text[]; candidate_religion integer;
  candidate_race integer; candidate_age integer; support_value text[]; i integer; ruler_race_name text; authority_name text;
begin
  a:=fauxlore.current_account();
  if path !~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then
    raise sqlstate '22023' using message='Некорректный запрос'; end if;
  state_value:=split_part(path,'/',3)::integer;
  if not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_value) then
    raise sqlstate '42501' using message='Нет доступа к этому государству'; end if;
  select * into state_row from fauxlore.state_profiles where state_id=state_value;
  if not found then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if path ~ '/birth-events/[0-9]+/name$' and method='POST' then
    birth_value:=split_part(path,'/',5)::bigint;
    if body-'names'<>'{}'::jsonb or jsonb_typeof(body->'names') is distinct from 'array' then raise sqlstate '22023' using message='Передайте список имён'; end if;
    if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);
    perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=character_lifecycle_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into event_row from fauxlore.state_birth_events where id=birth_value and state_id=state_value for update;
    if not found or event_row.named_at is not null then raise sqlstate 'P0002' using message='Событие рождения уже обработано или не найдено'; end if;
    names_value:=body->'names';
    if jsonb_array_length(names_value)<>jsonb_array_length(event_row.children) or exists(select 1 from jsonb_array_elements_text(names_value) x where length(btrim(x)) not between 1 and 120) then
      raise sqlstate '22023' using message='Укажите имя длиной от 1 до 120 символов для каждого ребёнка'; end if;
    for i in 0..jsonb_array_length(event_row.children)-1 loop
      child:=event_row.children->i;
      insert into fauxlore.state_characters(state_id,name,surname,gender,age,race_id,religion_id,legitimacy,father_id,mother_id)
      values(state_value,btrim(names_value->>i),coalesce((select surname from fauxlore.state_characters where id=event_row.father_id),''),
        child->>'gender',0,(child->>'race_id')::integer,(child->>'religion_id')::integer,child->>'legitimacy',event_row.father_id,event_row.mother_id);
    end loop;
    update fauxlore.state_birth_events set named_at=now() where id=birth_value;
    result:=jsonb_build_object('named',jsonb_array_length(names_value),'birth_id',birth_value);
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,character_lifecycle_api.request_id,fingerprint,result);
    return result;
  elsif path='my/states/'||state_value||'/birth-events' and method='GET' and body='{}'::jsonb then
    select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'year',e.year,'turn',e.turn,'children',e.children) order by e.year,e.id),'[]'::jsonb)
      into result from fauxlore.state_birth_events e where e.state_id=state_value and e.named_at is null;
    return result;
  elsif path='my/states/'||state_value||'/marriage-candidates' and method='GET' and body='{}'::jsonb then
    select * into ruler from fauxlore.state_characters where state_id=state_value and is_current_ruler and alive;
    if not found then return jsonb_build_object('candidates','[]'::jsonb,'message','Сейчас в государстве нет действующего правителя.'); end if;
    if exists(select 1 from fauxlore.state_marriages where ended_at_turn is null and ruler.id in(character_a_id,character_b_id)) then
      return jsonb_build_object('candidates','[]'::jsonb,'message','У правителя уже есть супруг.'); end if;
    if state_row.prestige<10 then return jsonb_build_object('candidates','[]'::jsonb,'message','Для местного брака требуется 10 ОП.'); end if;
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    perform pg_advisory_xact_lock(hashtextextended('marriage-candidates:'||state_value::text,0));
    if not exists(select 1 from fauxlore.state_marriage_candidates where state_id=state_value and created_turn=calendar_row.turn and selected_at is null) then
      gender_value:=case when ruler.gender='Мужской' then 'Женский' else 'Мужской' end;
      select name into ruler_race_name from fauxlore.map_categories where layer='races' and id=ruler.race_id;
      race_values:=array(select id from fauxlore.map_categories where layer='races' and name=any(
        case ruler_race_name when 'Люди' then array['Люди','Эльфы','Полуэльфы'] when 'Эльфы' then array['Люди','Эльфы','Полуэльфы']
          when 'Полуэльфы' then array['Люди','Эльфы','Полуэльфы'] when 'Дварфы' then array['Дварфы'] when 'Зверолюди' then array['Зверолюди'] else array[ruler_race_name] end));
      candidate_names:=case when gender_value='Женский' then array['Алиса','Велена','Дарья','Елена','Ирина','Лада','Мира','Надежда','Рада','Ярослава'] else array['Алексей','Борис','Владимир','Глеб','Дамир','Илья','Мирослав','Ратибор','Святослав','Яромир'] end;
      candidate_surnames:=array['Белоярский','Ветров','Зорин','Каменев','Лесной','Руднев','Серебряков','Сумеречный'];
      authority_name:=coalesce(state_row.principles->>'authority','');
      support_value:=case authority_name when 'Династия' then array['Корона','Знать'] when 'Магистрат' then array['Духовенство','Горожане']
        when 'Клир' then array['Духовенство'] when 'Диктат' then array['Корона'] when 'Вече' then array['Горожане','Крестьяне','Духовенство']
        else array['Корона','Знать','Духовенство','Горожане','Крестьяне'] end;
      for i in 1..3 loop
        candidate_race:=race_values[1+floor(random()*cardinality(race_values))::integer];
        select id into candidate_religion from fauxlore.map_categories where layer='religions' order by random() limit 1;
        candidate_age:=case when gender_value='Женский' then 18+floor(random()*27)::integer else 18+floor(random()*42)::integer end;
        insert into fauxlore.state_marriage_candidates(state_id,created_turn,name,surname,gender,age,race_id,religion_id,supported_by)
        values(state_value,calendar_row.turn,candidate_names[1+floor(random()*cardinality(candidate_names))::integer],candidate_surnames[1+floor(random()*cardinality(candidate_surnames))::integer],gender_value,candidate_age,candidate_race,candidate_religion,
          case when random()<.34 then array[support_value[1+floor(random()*cardinality(support_value))::integer]] else '{}'::text[] end);
      end loop;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'surname',c.surname,'gender',c.gender,'age',c.age,
      'race',(select name from fauxlore.map_categories where layer='races' and id=c.race_id),
      'religion',(select name from fauxlore.map_categories where layer='religions' and id=c.religion_id),'supported_by',c.supported_by) order by c.id),'[]'::jsonb)
      into result from fauxlore.state_marriage_candidates c where c.state_id=state_value and c.created_turn=calendar_row.turn and c.selected_at is null;
    return jsonb_build_object('candidates',result,'message','Выберите кандидата. Заключение местного брака стоит 10 ОП.');
  elsif path='my/states/'||state_value||'/marriages/local' and method='POST' then
    if body-'candidate_id'<>'{}'::jsonb or coalesce(body->>'candidate_id','') !~ '^\d+$' then raise sqlstate '22023' using message='Некорректный кандидат'; end if;
    if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);
    perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=character_lifecycle_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into ruler from fauxlore.state_characters where state_id=state_value and is_current_ruler and alive for update;
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    select * into candidate from fauxlore.state_marriage_candidates where id=(body->>'candidate_id')::bigint and state_id=state_value and created_turn=calendar_row.turn and selected_at is null for update;
    if not found then raise sqlstate 'P0002' using message='Кандидат устарел. Обновите список.'; end if;
    if ruler.id is null then raise sqlstate 'P0002' using message='Нет действующего правителя'; end if;
    if exists(select 1 from fauxlore.state_marriages where ended_at_turn is null and ruler.id in(character_a_id,character_b_id)) then raise sqlstate '22023' using message='У правителя уже есть супруг'; end if;
    if state_row.prestige<10 then raise sqlstate '22023' using message='Для местного брака требуется 10 ОП'; end if;
    authority_name:=coalesce(state_row.principles->>'authority','');
    select * into state_row from fauxlore.state_profiles where state_id=state_value for update;
    if state_row.prestige<10 then raise sqlstate '22023' using message='Для местного брака требуется 10 ОП'; end if;
    insert into fauxlore.state_characters(state_id,name,surname,gender,age,race_id,religion_id,legitimacy)
    values(state_value,candidate.name,candidate.surname,candidate.gender,candidate.age,candidate.race_id,candidate.religion_id,'Неприменимо') returning * into spouse_row;
    insert into fauxlore.state_marriages(character_a_id,character_b_id,marriage_type,lawful_for_a,lawful_for_b,started_at_turn)
    values(ruler.id,spouse_row.id,'local',authority_name='Династия',authority_name='Династия',calendar_row.turn);
    update fauxlore.state_marriage_candidates set selected_at=now() where id=(body->>'candidate_id')::bigint;
    update fauxlore.state_profiles set prestige=prestige-10 where state_id=state_value;
    result:=jsonb_build_object('married',true,'spouse_id',spouse_row.id,'cost',10);
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,character_lifecycle_api.request_id,fingerprint,result);
    insert into fauxlore.notifications(account_id,kind,title,message) values(a.id,'marriage','Заключён местный брак','Правитель заключил местный брак. Потрачено 10 ОП.');
    return result;
  end if;
  raise sqlstate '22023' using message='Недопустимый запрос';
end $$;
revoke all on function fauxlore.character_lifecycle_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.character_lifecycle_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$'
      then fauxlore.character_lifecycle_api(path,method,body,request_id)
    when path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$'
      then fauxlore.characters_api(path,method,body,request_id)
    when path='my/applications' and method='GET' then fauxlore.my_applications()
    when path='my/applications' and method='POST' then fauxlore.registration_api_with_surname(path,method,body,request_id)
    when path ~ '^admin/applications/[0-9]+$' and method='PATCH' then fauxlore.registration_api_with_surname(path,method,body,request_id)
    when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%'
      then fauxlore.registration_api(path,method,body,request_id)
    when path ~ '^my/applications/[0-9]+$' then fauxlore.application_details(path,method,body)
    when path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then fauxlore.state_emblem_api(path,method,body,request_id)
    when path='game/calendar' or path='admin/turn/advance' then fauxlore.turn_api(path,method,body,request_id)
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id)
  end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
