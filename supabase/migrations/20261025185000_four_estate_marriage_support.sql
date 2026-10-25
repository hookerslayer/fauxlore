-- Marriage-candidate support follows the four actual key estates.
CREATE OR REPLACE FUNCTION fauxlore.character_lifecycle_api(path text, method text, body jsonb, request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      support_value:=array(select e.estate from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) e(estate)
        where fauxlore.estate_status_for(state_value,e.estate)='Ключевое');
      for i in 1..3 loop
        candidate_race:=race_values[1+floor(random()*cardinality(race_values))::integer];
        select id into candidate_religion from fauxlore.map_categories where layer='religions' order by random() limit 1;
        candidate_age:=case when gender_value='Женский' then 18+floor(random()*27)::integer else 18+floor(random()*42)::integer end;
        insert into fauxlore.state_marriage_candidates(state_id,created_turn,name,surname,gender,age,race_id,religion_id,supported_by)
        values(state_value,calendar_row.turn,candidate_names[1+floor(random()*cardinality(candidate_names))::integer],candidate_surnames[1+floor(random()*cardinality(candidate_surnames))::integer],gender_value,candidate_age,candidate_race,candidate_religion,
          case when cardinality(support_value)>0 and random()<.34 then array[support_value[1+floor(random()*cardinality(support_value))::integer]] else '{}'::text[] end);
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
end $function$
;
