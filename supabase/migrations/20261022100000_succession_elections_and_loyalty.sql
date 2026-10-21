-- Complete the first playable ruler-transition loop: five-year elections,
-- voluntary abdication, designated successors, group loyalty and transition effects.
alter table fauxlore.state_profiles
  add column if not exists term_started_turn integer,
  add column if not exists designated_heir_id bigint references fauxlore.state_characters(id) on delete set null,
  add column if not exists designated_successor_id bigint references fauxlore.state_characters(id) on delete set null;

update fauxlore.state_profiles sp set term_started_turn=coalesce(sp.term_started_turn,c.turn)
from fauxlore.game_calendar c where c.singleton and sp.term_started_turn is null;

create table if not exists fauxlore.state_group_politics (
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  group_type text not null check(group_type in ('estate','race','religion')),
  group_key text not null,
  status text not null default 'Признание',
  loyalty numeric(5,4) not null default 0.5 check(loyalty between 0 and 1),
  recovery_target numeric(5,4),
  primary key(state_id,group_type,group_key)
);
alter table fauxlore.state_group_politics enable row level security;
revoke all on fauxlore.state_group_politics from public,anon,authenticated;

create or replace function fauxlore.estate_status_for(target_state integer,target_estate text)
returns text language plpgsql stable security definer set search_path='' as $$
declare p jsonb; authority_value text; economy_value text; i integer; result text;
begin
  select principles into p from fauxlore.state_profiles where state_id=target_state;
  authority_value:=p->>'authority'; economy_value:=p->>'economy';
  i:=array_position(array['Корона','Знать','Духовенство','Горожане','Крестьяне'],target_estate);
  if i is null then return '—'; end if;
  result:=case authority_value
    when 'Династия' then (array['Ключевое','Значимое','Значимое','Бесправное','Бесправное'])[i]
    when 'Магистрат' then (array['Бесправное','Значимое','Ключевое','Ключевое','Бесправное'])[i]
    when 'Клир' then (array['Значимое','Бесправное','Ключевое','Бесправное','Бесправное'])[i]
    when 'Диктат' then (array['Ключевое','Бесправное','Значимое','Бесправное','Бесправное'])[i]
    when 'Вече' then (array['Бесправное','Бесправное','Значимое','Значимое','Ключевое'])[i]
    else '—' end;
  if economy_value='Крепостничество' and i in (2,5) then result:=case i when 2 then 'Ключевое' else 'Бесправное' end;
  elsif economy_value='Гильдии' and i=4 then result:='Ключевое';
  elsif economy_value='Адмиралтейство' and i in (1,4) then result:=case i when 1 then 'Ключевое' else 'Значимое' end;
  elsif economy_value='Корсарство' and i=4 then result:='Значимое';
  elsif economy_value='Работорговля' and i=5 then result:='Бесправное'; end if;
  return coalesce(result,'—');
end $$;
revoke all on function fauxlore.estate_status_for(integer,text) from public,anon,authenticated;

create or replace function fauxlore.ensure_state_group_politics(target_state integer)
returns void language plpgsql security definer set search_path='' as $$
begin
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
  select target_state,'estate',e.name,fauxlore.estate_status_for(target_state,e.name)
  from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) e(name)
  on conflict(state_id,group_type,group_key) do update set status=excluded.status;
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
  select distinct target_state,v.layer,v.category_id::text,
    case when v.layer='races' and v.category_id=sp.official_race_id then 'Официальная'
         when v.layer='religions' and v.category_id=sp.official_religion_id then 'Официальная' else 'Признание' end
  from fauxlore.state_profiles sp
  join fauxlore.province_values sv on sv.layer='states' and sv.category_id=target_state
  join fauxlore.province_values v on v.province_id=sv.province_id and v.layer in ('races','religions')
  where sp.state_id=target_state
  on conflict(state_id,group_type,group_key) do update set status=excluded.status;
end $$;
revoke all on function fauxlore.ensure_state_group_politics(integer) from public,anon,authenticated;

create or replace function fauxlore.apply_ruler_change_effects(target_state integer,new_race integer,new_religion integer)
returns void language plpgsql security definer set search_path='' as $$
declare old_race integer; old_religion integer;
begin
  select official_race_id,official_religion_id into old_race,old_religion from fauxlore.state_profiles where state_id=target_state for update;
  perform fauxlore.ensure_state_group_politics(target_state);
  update fauxlore.state_group_politics set loyalty=case when loyalty<.5 then least(.5,loyalty+.10) when loyalty>.5 then greatest(.5,loyalty-.10) else .5 end
    where state_id=target_state;
  if new_race is distinct from old_race then
    update fauxlore.state_group_politics set status='Признание' where state_id=target_state and group_type='race' and group_key=old_race::text;
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status) values(target_state,'race',new_race::text,'Официальная')
      on conflict(state_id,group_type,group_key) do update set status='Официальная';
  end if;
  if new_religion is distinct from old_religion then
    update fauxlore.state_group_politics set status='Признание' where state_id=target_state and group_type='religion' and group_key=old_religion::text;
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status) values(target_state,'religion',new_religion::text,'Официальная')
      on conflict(state_id,group_type,group_key) do update set status='Официальная';
  end if;
end $$;
revoke all on function fauxlore.apply_ruler_change_effects(integer,integer,integer) from public,anon,authenticated;

create or replace function fauxlore.succession_annual_tick()
returns trigger language plpgsql security definer set search_path='' as $$
declare sp fauxlore.state_profiles; candidate_set jsonb; i integer; g fauxlore.state_group_politics;
  nm text[]:=array['Алексей','Борис','Владимир','Глеб','Дамир','Илья','Мирослав','Ратибор','Святослав','Яромир'];
  nf text[]:=array['Алиса','Велена','Дарья','Елена','Ирина','Лада','Мира','Надежда','Рада','Ярослава'];
  surnames text[]:=array['Белоярский','Ветров','Зорин','Каменев','Лесной','Руднев','Серебряков','Сумеречный'];
  gender_value text; race_value integer; religion_value integer; person jsonb; event_reason text;
begin
  if new.turn=old.turn then return new; end if;
  update fauxlore.state_group_politics set loyalty=least(recovery_target,loyalty+.01),
    recovery_target=case when least(recovery_target,loyalty+.01)>=recovery_target then null else recovery_target end
    where recovery_target is not null;
  for sp in select * from fauxlore.state_profiles where principles->>'authority' in ('Магистрат','Вече') loop
    if sp.term_started_turn is null then update fauxlore.state_profiles set term_started_turn=old.turn where state_id=sp.state_id; sp.term_started_turn:=old.turn; end if;
    if new.turn>=sp.term_started_turn+4 and not exists(select 1 from fauxlore.state_succession_events e where e.state_id=sp.state_id and e.resolved_at is null) then
      candidate_set:='[]'::jsonb;
      for i in 1..3 loop
        gender_value:=case when random()<.5 then 'Женский' else 'Мужской' end;
        if random()<.7 then race_value:=sp.official_race_id; else select rv.category_id into race_value from fauxlore.province_values sv join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer='races' where sv.layer='states' and sv.category_id=sp.state_id group by rv.category_id order by random() limit 1; end if;
        if sp.principles->>'authority'='Клир' or random()<.7 then religion_value:=sp.official_religion_id; else select rv.category_id into religion_value from fauxlore.province_values sv join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer='religions' where sv.layer='states' and sv.category_id=sp.state_id group by rv.category_id order by random() limit 1; end if;
        person:=jsonb_build_object('slot',i,'name',case when gender_value='Женский' then nf[1+floor(random()*cardinality(nf))::int] else nm[1+floor(random()*cardinality(nm))::int] end,
          'surname',surnames[1+floor(random()*cardinality(surnames))::int],'gender',gender_value,'age',18+floor(random()*43)::int,
          'race_id',coalesce(race_value,sp.official_race_id),'religion_id',coalesce(religion_value,sp.official_religion_id),
          'race',(select c.name from fauxlore.map_categories c where c.layer='races' and c.id=race_value),
          'religion',(select c.name from fauxlore.map_categories c where c.layer='religions' and c.id=religion_value));
        candidate_set:=candidate_set||jsonb_build_array(person);
      end loop;
      event_reason:=case when new.turn=sp.term_started_turn+4 then 'До окончания пятилетнего срока остался один год' else 'Истёк пятилетний срок полномочий' end;
      insert into fauxlore.state_succession_events(state_id,authority,event_type,reason,started_turn,resolves_turn,candidates)
      values(sp.state_id,sp.principles->>'authority','election',event_reason,new.turn,new.turn+1,candidate_set);
      insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'succession','Приближаются выборы правителя',event_reason||'. Откройте «Власть и династия», чтобы выбрать кандидата.'
      from fauxlore.account_states ast where ast.layer='states' and ast.state_id=sp.state_id;
    end if;
  end loop;
  return new;
end $$;
revoke all on function fauxlore.succession_annual_tick() from public,anon,authenticated;
drop trigger if exists game_calendar_succession_annual_tick on fauxlore.game_calendar;
create trigger game_calendar_succession_annual_tick after update of turn on fauxlore.game_calendar
for each row execute function fauxlore.succession_annual_tick();

-- Install the general transition effects for existing automatic and elected succession paths.
create or replace function fauxlore.resolve_ruler_succession()
returns trigger language plpgsql security definer set search_path='' as $$
declare event_row record; candidate jsonb; new_character fauxlore.state_characters; old_ruler fauxlore.state_characters;
  key_estate text; support_flag boolean;
begin
  if new.turn=old.turn then return new; end if;
  for event_row in select * from fauxlore.state_succession_events where resolved_at is null and chosen_at is not null and resolves_turn<=new.turn for update loop
    candidate:=event_row.chosen_candidate;
    select * into old_ruler from fauxlore.state_characters where state_id=event_row.state_id and is_current_ruler for update;
    update fauxlore.state_characters set is_current_ruler=false where state_id=event_row.state_id and is_current_ruler;
    insert into fauxlore.state_characters(state_id,name,surname,gender,age,race_id,religion_id,is_current_ruler)
    values(event_row.state_id,candidate->>'name',candidate->>'surname',candidate->>'gender',(candidate->>'age')::smallint,
      (candidate->>'race_id')::integer,(candidate->>'religion_id')::integer,true) returning * into new_character;
    perform fauxlore.apply_ruler_change_effects(event_row.state_id,new_character.race_id,new_character.religion_id);
    update fauxlore.state_profiles set prestige=10,ruler_name=new_character.name,ruler_surname=new_character.surname,
      ruler_gender=new_character.gender,ruler_title=new_character.title,ruler_age=new_character.age,
      official_race_id=new_character.race_id,official_religion_id=new_character.religion_id,term_started_turn=new.turn
      where state_id=event_row.state_id;
    update fauxlore.state_profiles set designated_heir_id=null,designated_successor_id=null where state_id=event_row.state_id;
    if jsonb_typeof(candidate->'support')='object' then
      for key_estate,support_flag in select key,value::text::boolean from jsonb_each(candidate->'support') loop
        if not support_flag then
          update fauxlore.state_group_politics set recovery_target=loyalty,loyalty=greatest(0,loyalty-.20)
          where state_id=event_row.state_id and group_type='estate' and group_key=key_estate;
        end if;
      end loop;
    end if;
    update fauxlore.state_succession_events set resolved_at=now() where id=event_row.id;
    insert into fauxlore.notifications(account_id,kind,title,message)
    select recipients.account_id,'succession','Вступил новый правитель','Правителем стал(а) '||new_character.name||' '||new_character.surname||'. Престиж установлен на 10 ОП; лояльность групп скорректирована.'
    from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=event_row.state_id
      union select ac.id from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.state_id=event_row.state_id)) recipients;
  end loop;
  return new;
end $$;

create or replace function fauxlore.succession_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_value integer; event_value bigint; candidate_slot integer; character_value bigint;
  event_row fauxlore.state_succession_events; previous fauxlore.operations; fingerprint text; actor_path text; sp fauxlore.state_profiles; has_event boolean; result jsonb;
begin
  a:=fauxlore.current_account(); actor_path:=split_part(path,'/',1);
  if path !~ '^(my|admin)/states/[0-9]+/succession(/events/[0-9]+/choose)?$|^(my|admin)/states/[0-9]+/(abdicate|designate)$|^(my|admin)/states/[0-9]+/politics$' then raise sqlstate '22023' using message='Некорректный запрос преемственности'; end if;
  state_value:=split_part(path,'/',3)::integer;
  if actor_path='admin' then if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  elsif not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_value) then raise sqlstate '42501' using message='Нет доступа к этому государству'; end if;
  if method='GET' and path=actor_path||'/states/'||state_value||'/politics' and body='{}'::jsonb then
    perform fauxlore.ensure_state_group_politics(state_value);
    return coalesce((select jsonb_agg(jsonb_build_object('group_type',group_type,'group_key',group_key,'status',status,'loyalty',loyalty,'recovery_target',recovery_target)
      order by group_type,group_key) from fauxlore.state_group_politics where state_id=state_value),'[]'::jsonb);
  end if;
  if method='GET' and path=actor_path||'/states/'||state_value||'/succession' and body='{}'::jsonb then
    select * into event_row from fauxlore.state_succession_events where state_id=state_value and resolved_at is null order by id desc limit 1;
    has_event:=found;
    select * into sp from fauxlore.state_profiles where state_id=state_value;
    if not has_event then return jsonb_build_object('pending',false,'designated_heir_id',sp.designated_heir_id,'designated_successor_id',sp.designated_successor_id); end if;
    return jsonb_build_object('pending',true,'id',event_row.id,'event_type',event_row.event_type,'authority',event_row.authority,'reason',event_row.reason,
      'resolves_turn',event_row.resolves_turn,'chosen',event_row.chosen_at is not null,'candidates',event_row.candidates,
      'designated_heir_id',sp.designated_heir_id,'designated_successor_id',sp.designated_successor_id);
  end if;
  if method='POST' and path=actor_path||'/states/'||state_value||'/abdicate' then
    if body-'confirmed'<>'{}' or body->>'confirmed'<>'true' or request_id is null then raise sqlstate '22023' using message='Требуется явное подтверждение отречения'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=succession_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into sp from fauxlore.state_profiles where state_id=state_value for update;
    update fauxlore.state_characters set alive=false,died_at_turn=(select turn from fauxlore.game_calendar where singleton),is_current_ruler=false
      where state_id=state_value and is_current_ruler and alive;
    if not found then raise sqlstate '22023' using message='Нет действующего правителя'; end if;
    insert into fauxlore.notifications(account_id,kind,title,message)
    select distinct ast.account_id,'succession','Правитель отрёкся','Правитель добровольно отрёкся от власти. Начата процедура передачи власти.' from fauxlore.account_states ast where ast.state_id=state_value and ast.layer='states';
    result:=jsonb_build_object('abdicated',true); insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result); return result;
  end if;
  if method='POST' and path=actor_path||'/states/'||state_value||'/designate' then
    if request_id is null or (body-'kind'-'character_id')<>'{}' or body->>'kind' not in ('heir','successor') or coalesce(body->>'character_id','') !~ '^[0-9]+$' then raise sqlstate '22023' using message='Укажите тип и персонажа'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=succession_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into sp from fauxlore.state_profiles where state_id=state_value for update;
    character_value:=(body->>'character_id')::bigint;
    if not exists(select 1 from fauxlore.state_characters ch where ch.id=character_value and ch.state_id=state_value and ch.alive and (body->>'kind'='heir' or ch.age>=16)) then raise sqlstate '22023' using message='Можно назначить только живого персонажа; преемник Диктата должен быть совершеннолетним'; end if;
    if body->>'kind'='heir' and (sp.principles->>'authority'<>'Династия' or not exists(select 1 from fauxlore.state_characters ch where ch.id=character_value and ch.legitimacy='Законный' and (ch.father_id=(select id from fauxlore.state_characters where state_id=state_value and is_current_ruler) or ch.mother_id=(select id from fauxlore.state_characters where state_id=state_value and is_current_ruler)))) then raise sqlstate '22023' using message='Наследником может быть только живой законный ребёнок правителя'; end if;
    if body->>'kind'='successor' and sp.principles->>'authority'<>'Диктат' then raise sqlstate '22023' using message='Назначенный преемник доступен только форме Диктат'; end if;
    if body->>'kind'='heir' then
      if coalesce(sp.prestige,0)<15 then raise sqlstate '22023' using message='Для назначения нужно 15 ОП'; end if;
      update fauxlore.state_profiles set designated_heir_id=character_value,prestige=prestige-15 where state_id=state_value;
      perform fauxlore.ensure_state_group_politics(state_value);
      update fauxlore.state_group_politics set loyalty=greatest(0,loyalty-.15) where state_id=state_value and group_type='estate' and status='Ключевое';
    else update fauxlore.state_profiles set designated_successor_id=character_value where state_id=state_value; end if;
    result:=jsonb_build_object('designated',true); insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result); return result;
  end if;
  if method='POST' and path ~ '^(my|admin)/states/[0-9]+/succession/events/[0-9]+/choose$' then
    if body-'candidate'<>'{}'::jsonb or coalesce(body->>'candidate','') !~ '^[1-3]$' or request_id is null then raise sqlstate '22023' using message='Выберите кандидата и повторите запрос'; end if;
    event_value:=split_part(path,'/',6)::bigint; candidate_slot:=(body->>'candidate')::integer;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=succession_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into event_row from fauxlore.state_succession_events where id=event_value and state_id=state_value and resolved_at is null for update;
    if not found then raise sqlstate 'P0002' using message='Событие передачи власти не найдено'; end if;
    if event_row.chosen_at is not null then raise sqlstate '22023' using message='Кандидат уже выбран'; end if;
    update fauxlore.state_succession_events set chosen_candidate=candidates->(candidate_slot-1),chosen_at=now() where id=event_row.id;
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,jsonb_build_object('chosen',candidate_slot,'resolves_turn',event_row.resolves_turn,'name',event_row.candidates->(candidate_slot-1)->>'name'));
    return (select result from fauxlore.operations where account_id=a.id and operations.request_id=succession_api.request_id);
  end if;
  raise sqlstate '22023' using message='Недопустимый запрос';
end $$;
revoke all on function fauxlore.succession_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.succession_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
 select case
  when path ~ '^(my|admin)/states/[0-9]+/(succession(/events/[0-9]+/choose)?|politics|abdicate|designate)$' then fauxlore.succession_api(path,method,body,request_id)
  when path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then fauxlore.character_lifecycle_api(path,method,body,request_id)
  when path ~ '^(my|admin)/states/[0-9]+/characters$' then fauxlore.characters_api(path,method,body,request_id)
  when path='my/applications' and method='GET' then fauxlore.my_applications()
  when path='my/applications' and method='POST' then fauxlore.registration_api_with_surname(path,method,body,request_id)
  when path ~ '^admin/applications/[0-9]+$' and method='PATCH' then fauxlore.registration_api_with_surname(path,method,body,request_id)
  when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%' then fauxlore.registration_api(path,method,body,request_id)
  when path ~ '^my/applications/[0-9]+$' then fauxlore.application_details(path,method,body)
  when path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then fauxlore.state_emblem_api(path,method,body,request_id)
  when path='game/calendar' or path='admin/turn/advance' then fauxlore.turn_api(path,method,body,request_id)
  when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
  when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
  else fauxlore.api(path,method,body,request_id) end
$$;

-- Prefer a previously designated lawful heir and apply the same transition
-- effects as an election when direct inheritance is immediate.
create or replace function fauxlore.start_ruler_succession()
returns trigger language plpgsql security definer set search_path='' as $$
declare sp fauxlore.state_profiles; heir fauxlore.state_characters; cal fauxlore.game_calendar;
  authority_value text; gender_value text; race_value integer; religion_value integer;
  names_m text[]:=array['Алексей','Борис','Владимир','Глеб','Дамир','Илья','Мирослав','Ратибор','Святослав','Яромир'];
  names_f text[]:=array['Алиса','Велена','Дарья','Елена','Ирина','Лада','Мира','Надежда','Рада','Ярослава'];
  surnames text[]:=array['Белоярский','Ветров','Зорин','Каменев','Лесной','Руднев','Серебряков','Сумеречный'];
  candidates_value jsonb:='[]'::jsonb; item jsonb; i integer; event_kind text; reason_value text;
begin
  if not old.alive or new.alive or not old.is_current_ruler then return new; end if;
  select * into sp from fauxlore.state_profiles where state_id=old.state_id for update;
  if not found or exists(select 1 from fauxlore.state_succession_events where state_id=old.state_id and resolved_at is null) then return new; end if;
  authority_value:=sp.principles->>'authority';
  select * into cal from fauxlore.game_calendar where singleton=true;
  if authority_value='Династия' then
    select * into heir from fauxlore.state_characters ch where ch.id=sp.designated_heir_id and ch.state_id=old.state_id and ch.alive and ch.legitimacy='Законный';
    if not found then
      select * into heir from fauxlore.state_characters ch where ch.state_id=old.state_id and ch.alive and ch.legitimacy='Законный'
        and old.id in(ch.father_id,ch.mother_id) order by ch.age desc,ch.created_at,ch.id limit 1;
    end if;
    if found then
      perform fauxlore.apply_ruler_change_effects(old.state_id,heir.race_id,heir.religion_id);
      update fauxlore.state_characters set is_current_ruler=false where state_id=old.state_id and is_current_ruler;
      update fauxlore.state_characters set is_current_ruler=true,is_regent=false where id=heir.id;
      update fauxlore.state_profiles set prestige=10,ruler_name=heir.name,ruler_surname=heir.surname,ruler_gender=heir.gender,
        ruler_title=heir.title,ruler_age=heir.age,official_race_id=heir.race_id,official_religion_id=heir.religion_id,
        term_started_turn=cal.turn,designated_heir_id=null,designated_successor_id=null where state_id=old.state_id;
      if heir.age<16 then
        gender_value:=case when random()<.5 then 'Женский' else 'Мужской' end;
        if random()<.7 then race_value:=sp.official_race_id; else select rv.category_id into race_value from fauxlore.province_values sv join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer='races' where sv.layer='states' and sv.category_id=old.state_id group by rv.category_id order by random() limit 1; end if;
        if random()<.7 then religion_value:=sp.official_religion_id; else select rv.category_id into religion_value from fauxlore.province_values sv join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer='religions' where sv.layer='states' and sv.category_id=old.state_id group by rv.category_id order by random() limit 1; end if;
        insert into fauxlore.state_characters(state_id,name,surname,gender,title,age,race_id,religion_id,is_regent)
        values(old.state_id,case when gender_value='Женский' then names_f[1+floor(random()*cardinality(names_f))::int] else names_m[1+floor(random()*cardinality(names_m))::int] end,
          surnames[1+floor(random()*cardinality(surnames))::int],gender_value,'Регент',greatest(16,18+floor(random()*35)::int),coalesce(race_value,sp.official_race_id),coalesce(religion_value,sp.official_religion_id),true);
      end if;
      insert into fauxlore.notifications(account_id,kind,title,message)
      select recipients.account_id,'succession','Наследник вступил на престол','После смерти правителя власть перешла к законному наследнику '||heir.name||' '||heir.surname||'.'||case when heir.age<16 then ' Назначен регент до совершеннолетия.' else '' end
      from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id
        union select ac.id from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id)) recipients;
      return new;
    end if;
    event_kind:='dynastic_candidates';reason_value:='Нет живого законного наследника';
  else event_kind:='election';reason_value:='Требуется избрать преемника по источнику власти «'||coalesce(authority_value,'не задан')||'»'; end if;
  for i in 1..3 loop
    gender_value:=case when random()<.5 then 'Женский' else 'Мужской' end;
    if authority_value='Клир' then religion_value:=sp.official_religion_id;
    elsif random()<.7 then religion_value:=sp.official_religion_id;
    else select id into religion_value from fauxlore.map_categories where layer='religions' order by random() limit 1; end if;
    if random()<.7 then race_value:=sp.official_race_id; else select rv.category_id into race_value from fauxlore.province_values sv join fauxlore.province_values rv on rv.province_id=sv.province_id and rv.layer='races' where sv.layer='states' and sv.category_id=old.state_id group by rv.category_id order by random() limit 1; end if;
    item:=jsonb_build_object('slot',i,'name',case when gender_value='Женский' then names_f[1+floor(random()*cardinality(names_f))::int] else names_m[1+floor(random()*cardinality(names_m))::int] end,
      'surname',surnames[1+floor(random()*cardinality(surnames))::int],'gender',gender_value,'age',18+floor(random()*43)::int,
      'race_id',race_value,'religion_id',religion_value,'race',(select c.name from fauxlore.map_categories c where c.layer='races' and c.id=race_value),
      'religion',(select c.name from fauxlore.map_categories c where c.layer='religions' and c.id=religion_value));
    candidates_value:=candidates_value||jsonb_build_array(item);
  end loop;
  insert into fauxlore.state_succession_events(state_id,authority,event_type,reason,started_turn,resolves_turn,candidates)
  values(old.state_id,authority_value,event_kind,reason_value,cal.turn,cal.turn+1,candidates_value);
  insert into fauxlore.notifications(account_id,kind,title,message)
  select recipients.account_id,'succession','Требуется передача власти',reason_value||'. Выберите кандидата; он вступит в должность после следующей смены хода.'
  from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id
    union select ac.id from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.state_id=old.state_id)) recipients;
  return new;
end $$;
revoke all on function fauxlore.start_ruler_succession() from public,anon,authenticated;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
