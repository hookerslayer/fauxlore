create index if not exists state_profiles_designated_heir_idx on fauxlore.state_profiles(designated_heir_id) where designated_heir_id is not null;
create index if not exists state_profiles_designated_successor_idx on fauxlore.state_profiles(designated_successor_id) where designated_successor_id is not null;

create or replace function fauxlore.province_value_for_state(target_province integer,target_state integer)
returns numeric language plpgsql stable security definer set search_path='' as $$
declare p fauxlore.provinces; race_name text; religion_name text; resource_name text;
  tax_mod numeric; prod_mod numeric; trade_mod numeric; trade_base numeric; trade_status_mod numeric;
  resource_value numeric:=0; resource_prod numeric:=0; crime_rate numeric; tax_value numeric; production_value numeric; trade_value numeric;
begin
  select * into p from fauxlore.provinces where id=target_province and kind='land';
  if not found then return null; end if;
  select c.name into race_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='races';
  select c.name into religion_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='religions';
  select c.name into resource_name from fauxlore.province_values v join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id where v.province_id=p.id and v.layer='resources';
  if race_name is null or religion_name is null then return null; end if;
  case p.province_type when 'Столичная' then tax_mod:=2; prod_mod:=1; trade_mod:=1.5; trade_base:=15;
    when 'Городская' then tax_mod:=1.5; prod_mod:=.7; trade_mod:=1; trade_base:=10;
    when 'Регион' then tax_mod:=.8; prod_mod:=1.2; trade_mod:=.5; trade_base:=2;
    when 'Территориальная' then tax_mod:=0; prod_mod:=0; trade_mod:=0; trade_base:=0;
    else return null; end case;
  trade_status_mod:=case coalesce(p.trade_status,'Отсутствует') when 'Отсутствует' then 1 when 'Устье реки' then 1.1
    when 'Природный порт' then 1.25 when 'Центр торговли I' then 1.25 when 'Центр торговли II' then 1.45 when 'Центр торговли III' then 1.65 else null end;
  if trade_status_mod is null then return null; end if;
  resource_value:=case resource_name when 'Зерно' then 1 when 'Лес' then 1 when 'Морепродукты' then 2 when 'Животноводство' then 3
    when 'Соль' then 4 when 'Хлопок' then 4 when 'Металлы' then 5 when 'Мех' then 5 when 'Красители' then 6 when 'Табак' then 6
    when 'Селитра' then 7 when 'Фрукты' then 7 when 'Сахар' then 6 when 'Чай' then 6 when 'Кофе' then 7 when 'Шёлк' then 8
    when 'Жемчуг' then 9 when 'Драгоценные металлы' then 10 when 'Эфемера' then 10 else 0 end;
  resource_prod:=case resource_name when 'Зерно' then .8 when 'Лес' then .6 when 'Морепродукты' then .4 when 'Животноводство' then .3
    when 'Соль' then .35 when 'Хлопок' then .25 when 'Металлы' then .2 when 'Мех' then .2 when 'Красители' then .15 when 'Табак' then .1
    when 'Селитра' then .1 when 'Фрукты' then .15 when 'Сахар' then .1 when 'Чай' then .08 when 'Кофе' then .08 when 'Шёлк' then .07
    when 'Жемчуг' then .05 when 'Драгоценные металлы' then .1 when 'Эфемера' then .1 else 0 end;
  select crime into crime_rate from fauxlore.state_profiles where state_id=target_state;
  crime_rate:=coalesce(crime_rate,.2);
  tax_value:=round(greatest(0,p.population)::numeric/10*.2*tax_mod*(coalesce(p.control,100)::numeric/100),2);
  production_value:=round(greatest(0,p.population)::numeric*resource_prod*prod_mod*(coalesce(p.control,100)::numeric/100)*(1-crime_rate),0);
  trade_value:=round(trade_base*trade_mod*trade_status_mod,2);
  return round(((tax_value+production_value*resource_value)*.001)+(trade_value*.005)+(production_value*resource_value*.005)+(greatest(0,p.population)*.0005),0);
end $$;
revoke all on function fauxlore.province_value_for_state(integer,integer) from public,anon,authenticated;

create or replace function fauxlore.apply_ruler_change_effects(target_state integer,new_race integer,new_religion integer)
returns void language plpgsql security definer set search_path='' as $$
declare old_race integer; old_religion integer;
begin
  select official_race_id,official_religion_id into old_race,old_religion from fauxlore.state_profiles where state_id=target_state for update;
  perform fauxlore.ensure_state_group_politics(target_state);
  update fauxlore.state_group_politics set loyalty=case when loyalty<.5 then least(.5,loyalty+.10) when loyalty>.5 then greatest(.5,loyalty-.10) else .5 end where state_id=target_state;
  if new_race is distinct from old_race then
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status) values(target_state,'race',old_race::text,'Признание')
      on conflict(state_id,group_type,group_key) do update set status='Признание';
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status) values(target_state,'race',new_race::text,'Официальная')
      on conflict(state_id,group_type,group_key) do update set status='Официальная';
  end if;
  if new_religion is distinct from old_religion then
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status) values(target_state,'religion',old_religion::text,'Признание')
      on conflict(state_id,group_type,group_key) do update set status='Признание';
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status) values(target_state,'religion',new_religion::text,'Официальная')
      on conflict(state_id,group_type,group_key) do update set status='Официальная';
  end if;
end $$;
revoke all on function fauxlore.apply_ruler_change_effects(integer,integer,integer) from public,anon,authenticated;

create or replace function fauxlore.succession_annual_tick()
returns trigger language plpgsql security definer set search_path='' as $$
declare sp fauxlore.state_profiles; candidate_set jsonb; i integer; race_value integer; religion_value integer;
  nm text[]:=array['Алексей','Борис','Владимир','Глеб','Дамир','Илья','Мирослав','Ратибор','Святослав','Яромир'];
  nf text[]:=array['Алиса','Велена','Дарья','Елена','Ирина','Лада','Мира','Надежда','Рада','Ярослава'];
  surnames text[]:=array['Белоярский','Ветров','Зорин','Каменев','Лесной','Руднев','Серебряков','Сумеречный'];
  gender_value text; person jsonb; event_reason text;
begin
  if new.turn=old.turn then return new; end if;
  update fauxlore.state_group_politics set loyalty=least(recovery_target,loyalty+.01),recovery_target=case when least(recovery_target,loyalty+.01)>=recovery_target then null else recovery_target end where recovery_target is not null;
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
          'race',(select c.name from fauxlore.map_categories c where c.layer='races' and c.id=coalesce(race_value,sp.official_race_id)),
          'religion',(select c.name from fauxlore.map_categories c where c.layer='religions' and c.id=coalesce(religion_value,sp.official_religion_id)));
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

create or replace function fauxlore.resolve_designated_dictator()
returns trigger language plpgsql security definer set search_path='' as $$
declare event_row fauxlore.state_succession_events; sp fauxlore.state_profiles; designee fauxlore.state_characters;
  candidate jsonb; total_key_weight numeric; support_weight numeric; is_supported boolean;
begin
  if not old.alive or new.alive or not old.is_current_ruler then return new; end if;
  select * into sp from fauxlore.state_profiles where state_id=old.state_id and principles->>'authority'='Диктат' and designated_successor_id is not null;
  if not found then return new; end if;
  select * into designee from fauxlore.state_characters where id=sp.designated_successor_id and state_id=old.state_id and alive and age>=16;
  if not found then return new; end if;
  select * into event_row from fauxlore.state_succession_events where state_id=old.state_id and resolved_at is null order by id desc limit 1 for update;
  if not found then return new; end if;
  candidate:=event_row.candidates->0;
  candidate:=candidate||jsonb_build_object('name',designee.name,'surname',designee.surname,'gender',designee.gender,'age',designee.age,
    'race_id',designee.race_id,'religion_id',designee.religion_id,'race',(select name from fauxlore.map_categories where layer='races' and id=designee.race_id),
    'religion',(select name from fauxlore.map_categories where layer='religions' and id=designee.religion_id),'designated',true);
  update fauxlore.state_succession_events set candidates=jsonb_set(candidates,'{0}',candidate,true) where id=event_row.id returning * into event_row;
  select coalesce(sum(fauxlore.province_value_for_state(p.id,old.state_id)),0) into total_key_weight
    from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
    where s.layer='states' and s.category_id=old.state_id and fauxlore.estate_status_for(old.state_id,p.belonging)='Ключевое';
  support_weight:=coalesce((candidate->>'support_weight')::numeric,0);
  is_supported:=total_key_weight>0 and support_weight>total_key_weight/2;
  if not is_supported then return new; end if;
  update fauxlore.state_characters set is_current_ruler=false where state_id=old.state_id and is_current_ruler;
  update fauxlore.state_characters set is_current_ruler=true where id=designee.id;
  perform fauxlore.apply_ruler_change_effects(old.state_id,designee.race_id,designee.religion_id);
  update fauxlore.state_profiles set prestige=10,ruler_name=designee.name,ruler_surname=designee.surname,ruler_gender=designee.gender,
    ruler_title=designee.title,ruler_age=designee.age,official_race_id=designee.race_id,official_religion_id=designee.religion_id,
    term_started_turn=(select turn from fauxlore.game_calendar where singleton),designated_heir_id=null,designated_successor_id=null where state_id=old.state_id;
  update fauxlore.state_succession_events set chosen_candidate=candidate,chosen_at=now(),resolved_at=now() where id=event_row.id;
  update fauxlore.notifications set title='Назначенный преемник вступил во власть',message=designee.name||' '||designee.surname||' получил(а) поддержку большинства влияния ключевых сословий и немедленно вступил(а) в должность.'
    where kind='succession' and title='Требуется передача власти' and created_at>now()-interval '1 minute';
  return new;
end $$;
revoke all on function fauxlore.resolve_designated_dictator() from public,anon,authenticated;
drop trigger if exists state_character_z_resolve_designated_dictator on fauxlore.state_characters;
create trigger state_character_z_resolve_designated_dictator after update of alive on fauxlore.state_characters
for each row when(old.alive and not new.alive and old.is_current_ruler) execute function fauxlore.resolve_designated_dictator();

create or replace function fauxlore.prepare_succession_support()
returns trigger language plpgsql security definer set search_path='' as $$
declare candidate jsonb; prepared jsonb:='[]'::jsonb; support_map jsonb; estate_name text; slot integer; i integer;
  estate_weights jsonb:='{}'::jsonb; estate_weight numeric; total_weight numeric:=0; chosen_slot integer;
  province_votes integer[]:=array[0,0,0]; authority_value text; is_key boolean;
begin
  perform fauxlore.ensure_state_group_politics(new.state_id);
  authority_value:=new.authority;
  if authority_value='Вече' then
    for i in select 1+floor(random()*3)::int from fauxlore.province_values where layer='states' and category_id=new.state_id loop
      province_votes[i]:=province_votes[i]+1;
    end loop;
  end if;
  for i in 0..jsonb_array_length(new.candidates)-1 loop
    candidate:=new.candidates->i; support_map:='{}'::jsonb;
    for estate_name in select unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) loop
      is_key:=fauxlore.estate_status_for(new.state_id,estate_name)='Ключевое';
      if authority_value='Клир' and estate_name<>'Духовенство' then continue; end if;
      if authority_value in ('Династия','Диктат') and not is_key then continue; end if;
      if authority_value='Вече' then continue; end if;
      select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id)),0) into estate_weight
      from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
      where s.layer='states' and s.category_id=new.state_id and p.belonging=estate_name;
      if estate_weight<=0 then estate_weight:=1; end if;
      estate_weights:=jsonb_set(estate_weights,array[estate_name],to_jsonb(estate_weight),true);
      total_weight:=total_weight+estate_weight;
      chosen_slot:=1+floor(random()*3)::int;
      support_map:=support_map||jsonb_build_object(estate_name,chosen_slot=i);
    end loop;
    if authority_value='Вече' then
      candidate:=jsonb_set(candidate,'{support_votes}',to_jsonb(province_votes[i+1]),true);
    else
      candidate:=jsonb_set(candidate,'{support}',support_map,true);
      candidate:=jsonb_set(candidate,'{support_weight}',to_jsonb((select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id)),0)
        from fauxlore.province_values sv join fauxlore.provinces p on p.id=sv.province_id and p.kind='land'
        where sv.layer='states' and sv.category_id=new.state_id and p.belonging in(select key from jsonb_each(support_map) where value='true'::jsonb))),true);
    end if;
    prepared:=prepared||jsonb_build_array(candidate);
  end loop;
  if authority_value='Вече' then
    prepared:=(select jsonb_agg(jsonb_set(prepared->(n-1),'{support_votes}',to_jsonb(province_votes[n]),true) order by n) from generate_series(1,3) n);
  end if;
  new.candidates:=prepared;
  return new;
end $$;
revoke all on function fauxlore.prepare_succession_support() from public,anon,authenticated;
drop trigger if exists state_succession_prepare_support on fauxlore.state_succession_events;
create trigger state_succession_prepare_support before insert on fauxlore.state_succession_events
for each row execute function fauxlore.prepare_succession_support();

-- Only a dynastic candidate selected against the randomly recorded support of
-- key estates causes the specified -20 percentage-point reaction.
create or replace function fauxlore.resolve_ruler_succession()
returns trigger language plpgsql security definer set search_path='' as $$
declare event_row record; candidate jsonb; new_character fauxlore.state_characters; key_estate text; support_flag boolean;
begin
  if new.turn=old.turn then return new; end if;
  for event_row in select * from fauxlore.state_succession_events where resolved_at is null and chosen_at is not null and resolves_turn<=new.turn for update loop
    candidate:=event_row.chosen_candidate;
    update fauxlore.state_characters set is_current_ruler=false where state_id=event_row.state_id and is_current_ruler;
    insert into fauxlore.state_characters(state_id,name,surname,gender,age,race_id,religion_id,is_current_ruler)
    values(event_row.state_id,candidate->>'name',candidate->>'surname',candidate->>'gender',(candidate->>'age')::smallint,
      (candidate->>'race_id')::integer,(candidate->>'religion_id')::integer,true) returning * into new_character;
    perform fauxlore.apply_ruler_change_effects(event_row.state_id,new_character.race_id,new_character.religion_id);
    update fauxlore.state_profiles set prestige=10,ruler_name=new_character.name,ruler_surname=new_character.surname,ruler_gender=new_character.gender,
      ruler_title=new_character.title,ruler_age=new_character.age,official_race_id=new_character.race_id,official_religion_id=new_character.religion_id,
      term_started_turn=new.turn,designated_heir_id=null,designated_successor_id=null where state_id=event_row.state_id;
    if event_row.event_type='dynastic_candidates' and jsonb_typeof(candidate->'support')='object' then
      for key_estate,support_flag in select key,value::text::boolean from jsonb_each(candidate->'support') loop
        if not support_flag then update fauxlore.state_group_politics set recovery_target=loyalty,loyalty=greatest(0,loyalty-.20)
          where state_id=event_row.state_id and group_type='estate' and group_key=key_estate; end if;
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
revoke all on function fauxlore.resolve_ruler_succession() from public,anon,authenticated;
notify pgrst,'reload schema';
