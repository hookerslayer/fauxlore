-- First playable succession stage: automatic dynastic heirs and a one-turn
-- selection process after a ruler's death for other authorities/no-heir cases.
create table if not exists fauxlore.state_succession_events (
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  authority text not null,
  event_type text not null check(event_type in ('dynastic_candidates','election')),
  reason text not null,
  started_turn integer not null,
  resolves_turn integer not null,
  candidates jsonb not null check(jsonb_typeof(candidates)='array' and jsonb_array_length(candidates)=3),
  chosen_candidate jsonb,
  chosen_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists state_succession_one_pending_idx
  on fauxlore.state_succession_events(state_id) where resolved_at is null;
create index if not exists state_succession_pending_idx
  on fauxlore.state_succession_events(resolves_turn) where chosen_at is not null and resolved_at is null;
alter table fauxlore.state_succession_events enable row level security;
revoke all on fauxlore.state_succession_events from public,anon,authenticated;

create or replace function fauxlore.state_characters_payload(target_state_id integer)
returns jsonb language sql security definer set search_path='' as $$
  with ruler as (
    select ch.* from fauxlore.state_characters ch where ch.state_id=target_state_id and (ch.is_current_ruler or not exists(
      select 1 from fauxlore.state_characters active where active.state_id=target_state_id and active.is_current_ruler))
    order by ch.is_current_ruler desc,ch.id desc limit 1
  ), relevant as (
    select distinct ch.*,
      case when ch.is_regent then 'Регент'
        when ch.id=(select id from ruler) then case when ch.is_current_ruler then 'Правитель' else 'Бывший правитель' end
        when exists(select 1 from fauxlore.state_marriages m where
          ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler)) or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
          then case when exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and
            ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler)) or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
            then case when ch.gender='Женский' then 'Супруга' else 'Супруг' end else 'Бывший супруг' end
        when ch.id in ((select father_id from ruler),(select mother_id from ruler)) then 'Родитель'
        when (select id from ruler) in (ch.father_id,ch.mother_id) then 'Ребёнок'
        when exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
          and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id)) or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))) then 'Брат/сестра'
        else 'Родственник' end as relation
    from fauxlore.state_characters ch where ch.state_id=target_state_id and (ch.is_regent or ch.is_current_ruler or ch.id=(select id from ruler)
      or ch.id in ((select father_id from ruler),(select mother_id from ruler)) or (select id from ruler) in (ch.father_id,ch.mother_id)
      or exists(select 1 from fauxlore.state_marriages m where (m.character_a_id=ch.id and m.character_b_id=(select id from ruler))
        or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler)))
      or exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
        and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id)) or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))))
    union
    select ch.*,case when ch.gender='Женский' then 'Супруга' else 'Супруг' end as relation from fauxlore.state_marriages m
    join fauxlore.state_characters ch on ch.id=case when m.character_a_id=(select id from ruler) then m.character_b_id else m.character_a_id end
    where (m.character_a_id=(select id from ruler) or m.character_b_id=(select id from ruler)) and ch.state_id<>target_state_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'surname',r.surname,'gender',r.gender,'title',r.title,'age',r.age,
    'race_id',r.race_id,'religion_id',r.religion_id,'race',(select c.name from fauxlore.map_categories c where c.layer='races' and c.id=r.race_id),
    'religion',(select c.name from fauxlore.map_categories c where c.layer='religions' and c.id=r.religion_id),
    'alive',r.alive,'legitimacy',r.legitimacy,'is_current_ruler',r.is_current_ruler,'is_regent',r.is_regent,'relationship',r.relation,
    'state_name',(select c.name from fauxlore.map_categories c where c.layer='states' and c.id=r.state_id)
  ) order by r.is_current_ruler desc,r.is_regent desc,r.age desc,r.id),'[]'::jsonb) from relevant r
$$;
revoke all on function fauxlore.state_characters_payload(integer) from public,anon,authenticated;

create or replace function fauxlore.start_ruler_succession()
returns trigger language plpgsql security definer set search_path='' as $$
declare profile_row fauxlore.state_profiles; calendar_row fauxlore.game_calendar;
  heir fauxlore.state_characters; old_ruler fauxlore.state_characters;
  authority_value text; candidates_value jsonb:='[]'::jsonb; i integer;
  names_m text[]:=array['Алексей','Борис','Владимир','Глеб','Дамир','Илья','Мирослав','Ратибор','Святослав','Яромир'];
  names_f text[]:=array['Алиса','Велена','Дарья','Елена','Ирина','Лада','Мира','Надежда','Рада','Ярослава'];
  surnames text[]:=array['Белоярский','Ветров','Зорин','Каменев','Лесной','Руднев','Серебряков','Сумеречный'];
  gender_value text; race_value integer; religion_value integer; candidate_value jsonb;
  event_type_value text; reason_value text; account_value bigint;
begin
  if not old.alive or new.alive or not old.is_current_ruler then return new; end if;
  select * into profile_row from fauxlore.state_profiles where state_id=old.state_id for update;
  if not found then return new; end if;
  if exists(select 1 from fauxlore.state_succession_events where state_id=old.state_id and resolved_at is null) then return new; end if;
  authority_value:=coalesce(profile_row.principles->>'authority','');
  select * into calendar_row from fauxlore.game_calendar where singleton=true;

  if authority_value='Династия' then
    select * into heir from fauxlore.state_characters ch
    where ch.state_id=old.state_id and ch.alive and ch.legitimacy='Законный'
      and old.id in(ch.father_id,ch.mother_id)
    order by ch.age desc,ch.created_at asc,ch.id asc limit 1 for update;
    if found then
      update fauxlore.state_characters set is_current_ruler=false where state_id=old.state_id and is_current_ruler;
      update fauxlore.state_characters set is_current_ruler=true,is_regent=false where id=heir.id;
      update fauxlore.state_profiles set prestige=10,ruler_name=heir.name,ruler_surname=heir.surname,
        ruler_gender=heir.gender,ruler_title=heir.title,ruler_age=heir.age,
        official_race_id=heir.race_id,official_religion_id=heir.religion_id where state_id=old.state_id;
      if heir.age<16 then
        gender_value:=case when random()<.5 then 'Женский' else 'Мужской' end;
        if random()<.7 then race_value:=profile_row.official_race_id;
        else select id into race_value from fauxlore.map_categories where layer='races' order by random() limit 1; end if;
        if random()<.7 then religion_value:=profile_row.official_religion_id;
        else select id into religion_value from fauxlore.map_categories where layer='religions' order by random() limit 1; end if;
        insert into fauxlore.state_characters(state_id,name,surname,gender,title,age,race_id,religion_id,is_regent)
        values(old.state_id,case when gender_value='Женский' then names_f[1+floor(random()*cardinality(names_f))::int] else names_m[1+floor(random()*cardinality(names_m))::int] end,
          surnames[1+floor(random()*cardinality(surnames))::int],gender_value,'Регент',greatest(16,18+floor(random()*35)::int),
          coalesce(race_value,profile_row.official_race_id),coalesce(religion_value,profile_row.official_religion_id),true);
      end if;
      insert into fauxlore.notifications(account_id,kind,title,message)
      select recipients.account_id,'succession','Наследник вступил на престол',
        'После смерти правителя власть перешла к законному наследнику '||heir.name||' '||heir.surname||'.'||
        case when heir.age<16 then ' До его совершеннолетия назначен регент.' else '' end
      from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id
        union select ac.id from fauxlore.accounts ac where ac.role='admin'
          and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id)) recipients;
      return new;
    end if;
    event_type_value:='dynastic_candidates';reason_value:='Нет живого законного наследника';
  else
    event_type_value:='election';reason_value:='Требуется избрать преемника по источнику власти «'||authority_value||'»';
  end if;

  for i in 1..3 loop
    gender_value:=case when random()<.5 then 'Женский' else 'Мужской' end;
    if random()<.7 then race_value:=profile_row.official_race_id;
    else select id into race_value from fauxlore.map_categories where layer='races' order by random() limit 1; end if;
    if random()<.7 then religion_value:=profile_row.official_religion_id;
    else select id into religion_value from fauxlore.map_categories where layer='religions' order by random() limit 1; end if;
    candidate_value:=jsonb_build_object('slot',i,'name',case when gender_value='Женский' then names_f[1+floor(random()*cardinality(names_f))::int] else names_m[1+floor(random()*cardinality(names_m))::int] end,
      'surname',surnames[1+floor(random()*cardinality(surnames))::int],'gender',gender_value,'age',18+floor(random()*43)::int,
      'race_id',race_value,'religion_id',religion_value,
      'race',(select name from fauxlore.map_categories where layer='races' and id=race_value),
      'religion',(select name from fauxlore.map_categories where layer='religions' and id=religion_value));
    candidates_value:=candidates_value||jsonb_build_array(candidate_value);
  end loop;
  insert into fauxlore.state_succession_events(state_id,authority,event_type,reason,started_turn,resolves_turn,candidates)
  values(old.state_id,authority_value,event_type_value,reason_value,calendar_row.turn,calendar_row.turn+1,candidates_value);
  insert into fauxlore.notifications(account_id,kind,title,message)
  select recipients.account_id,'succession','Требуется передача власти',reason_value||'. Выберите одного из трёх кандидатов; избранный вступит в должность после следующей смены хода.'
  from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id
    union select ac.id from fauxlore.accounts ac where ac.role='admin'
      and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id)) recipients;
  return new;
end $$;
revoke all on function fauxlore.start_ruler_succession() from public,anon,authenticated;
create trigger state_character_ruler_death_succession
after update of alive on fauxlore.state_characters
for each row when (old.alive and not new.alive and old.is_current_ruler)
execute function fauxlore.start_ruler_succession();

create or replace function fauxlore.resolve_ruler_succession()
returns trigger language plpgsql security definer set search_path='' as $$
declare event_row record; candidate jsonb; new_character fauxlore.state_characters;
begin
  if new.turn=old.turn then return new; end if;
  for event_row in select * from fauxlore.state_succession_events
    where resolved_at is null and chosen_at is not null and resolves_turn<=new.turn for update
  loop
    candidate:=event_row.chosen_candidate;
    update fauxlore.state_characters set is_current_ruler=false where state_id=event_row.state_id and is_current_ruler;
    insert into fauxlore.state_characters(state_id,name,surname,gender,age,race_id,religion_id,is_current_ruler)
    values(event_row.state_id,candidate->>'name',candidate->>'surname',candidate->>'gender',
      (candidate->>'age')::smallint,(candidate->>'race_id')::integer,(candidate->>'religion_id')::integer,true)
    returning * into new_character;
    update fauxlore.state_profiles set prestige=10,ruler_name=new_character.name,ruler_surname=new_character.surname,
      ruler_gender=new_character.gender,ruler_title=new_character.title,ruler_age=new_character.age,
      official_race_id=new_character.race_id,official_religion_id=new_character.religion_id
      where state_id=event_row.state_id;
    update fauxlore.state_succession_events set resolved_at=now() where id=event_row.id;
    insert into fauxlore.notifications(account_id,kind,title,message)
    select recipients.account_id,'succession','Вступил новый правитель',
      'Правителем стал(а) '||new_character.name||' '||new_character.surname||'. Престиж государства установлен на 10 ОП.'
    from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=event_row.state_id
      union select ac.id from fauxlore.accounts ac where ac.role='admin'
        and not exists(select 1 from fauxlore.account_states ast where ast.state_id=event_row.state_id)) recipients;
  end loop;
  return new;
end $$;
revoke all on function fauxlore.resolve_ruler_succession() from public,anon,authenticated;
create trigger game_calendar_resolve_succession
after update of turn on fauxlore.game_calendar
for each row execute function fauxlore.resolve_ruler_succession();

create or replace function fauxlore.succession_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_value integer; event_value bigint; candidate_slot integer;
  event_row fauxlore.state_succession_events; previous fauxlore.operations; fingerprint text;
begin
  a:=fauxlore.current_account();
  if path !~ '^my/states/[0-9]+/succession(/events/[0-9]+/choose)?$' then raise sqlstate '22023' using message='Некорректный запрос преемственности'; end if;
  state_value:=split_part(path,'/',3)::integer;
  if not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_value) then
    raise sqlstate '42501' using message='Нет доступа к этому государству'; end if;
  if method='GET' and path='my/states/'||state_value||'/succession' and body='{}'::jsonb then
    select * into event_row from fauxlore.state_succession_events where state_id=state_value and resolved_at is null order by id desc limit 1;
    if not found then return jsonb_build_object('pending',false); end if;
    return jsonb_build_object('pending',true,'id',event_row.id,'event_type',event_row.event_type,'authority',event_row.authority,
      'reason',event_row.reason,'resolves_turn',event_row.resolves_turn,'chosen',event_row.chosen_at is not null,
      'candidates',event_row.candidates);
  end if;
  if method='POST' and path ~ '^my/states/[0-9]+/succession/events/[0-9]+/choose$' then
    if body-'candidate'<>'{}'::jsonb or coalesce(body->>'candidate','') !~ '^[1-3]$' or request_id is null then
      raise sqlstate '22023' using message='Выберите кандидата и повторите запрос'; end if;
    event_value:=split_part(path,'/',6)::bigint;candidate_slot:=(body->>'candidate')::integer;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);
    perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=succession_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into event_row from fauxlore.state_succession_events where id=event_value and state_id=state_value and resolved_at is null for update;
    if not found then raise sqlstate 'P0002' using message='Событие передачи власти не найдено'; end if;
    if event_row.chosen_at is not null then raise sqlstate '22023' using message='Кандидат уже выбран'; end if;
    update fauxlore.state_succession_events set chosen_candidate=candidates->(candidate_slot-1),chosen_at=now() where id=event_row.id;
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,
      jsonb_build_object('chosen',candidate_slot,'resolves_turn',event_row.resolves_turn,'name',event_row.candidates->(candidate_slot-1)->>'name'));
    return (select result from fauxlore.operations where account_id=a.id and operations.request_id=succession_api.request_id);
  end if;
  raise sqlstate '22023' using message='Недопустимый запрос';
end $$;
revoke all on function fauxlore.succession_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.succession_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path ~ '^my/states/[0-9]+/succession(/events/[0-9]+/choose)?$' then fauxlore.succession_api(path,method,body,request_id)
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
