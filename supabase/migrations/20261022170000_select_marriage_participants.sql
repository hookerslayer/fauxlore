create or replace function fauxlore.child_race_for_parents(race_a text,race_b text)
returns text language sql immutable set search_path='' as $$
  select case
    when race_a=race_b and race_a in ('Люди','Эльфы','Дварфы','Зверолюди') then race_a
    when race_a in ('Люди','Эльфы','Полуэльфы') and race_b in ('Люди','Эльфы','Полуэльфы')
      then case when race_a='Люди' and race_b='Люди' then 'Люди'
                when race_a='Эльфы' and race_b='Эльфы' then 'Эльфы' else 'Полуэльфы' end
    else null end;
$$;
revoke all on function fauxlore.child_race_for_parents(text,text) from public,anon,authenticated;

create or replace function fauxlore.dynastic_marriage_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; proposal fauxlore.state_marriage_proposals; previous fauxlore.operations;
  proposal_id bigint; from_state integer; to_state integer; actor_state integer;
  from_person fauxlore.state_characters; to_person fauxlore.state_characters;
  from_profile fauxlore.state_profiles; to_profile fauxlore.state_profiles;
  calendar_row fauxlore.game_calendar; fingerprint text; result jsonb; lawful boolean; actor text; action text;
  from_race text; to_race text; child_race text; male_age integer; female_age integer; can_conceive boolean;
begin
  a:=fauxlore.current_account(); actor:=split_part(path,'/',1);
  if path not in ('my/marriage-offers') and path !~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then raise sqlstate '22023' using message='Некорректный запрос династического брака'; end if;
  if actor='admin' and a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if path='my/marriage-offers' and method='GET' and body='{}'::jsonb then
    if a.role='admin' then
      return jsonb_build_object(
        'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority') order by c.name) from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id where c.layer='states'),'[]'::jsonb),
        'targets',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority') order by c.name) from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id where c.layer='states'),'[]'::jsonb),
        'participants',coalesce((select jsonb_agg(jsonb_build_object('id',ch.id,'state_id',ch.state_id,'name',ch.name,'surname',ch.surname,'gender',ch.gender,'age',ch.age,'race',rc.name,'race_id',ch.race_id) order by ch.state_id,ch.name)
          from fauxlore.state_characters ch left join fauxlore.map_categories rc on rc.layer='races' and rc.id=ch.race_id
          where ch.alive and ch.age>=16 and ch.gender in ('Мужской','Женский') and not exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and ch.id in(m.character_a_id,m.character_b_id))),'[]'::jsonb),
        'incoming',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'from_state_id',p.from_state_id,'from_state',fc.name,'to_state_id',p.to_state_id,'to_state',tc.name,
          'from_ruler',fa.name||' '||coalesce(fa.surname,''),'to_ruler',ta.name||' '||coalesce(ta.surname,''),'created_at',p.created_at) order by p.created_at desc)
          from fauxlore.state_marriage_proposals p join fauxlore.map_categories fc on fc.layer='states' and fc.id=p.from_state_id join fauxlore.map_categories tc on tc.layer='states' and tc.id=p.to_state_id
          join fauxlore.state_characters fa on fa.id=p.from_character_id join fauxlore.state_characters ta on ta.id=p.to_character_id where p.status='pending'),'[]'::jsonb),
        'outgoing','[]'::jsonb);
    end if;
    return jsonb_build_object(
      'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority') order by c.name)
        from fauxlore.account_states ast join fauxlore.map_categories c on c.layer=ast.layer and c.id=ast.state_id join fauxlore.state_profiles sp on sp.state_id=c.id where ast.account_id=a.id and ast.layer='states'),'[]'::jsonb),
      'targets',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'authority',sp.principles->>'authority') order by c.name)
        from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id where c.layer='states'
          and not exists(select 1 from fauxlore.account_states mine where mine.account_id=a.id and mine.layer='states' and mine.state_id=c.id)
          and exists(select 1 from fauxlore.state_characters ch where ch.state_id=c.id and ch.alive and ch.age>=16 and ch.gender in ('Мужской','Женский')
            and not exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and ch.id in(m.character_a_id,m.character_b_id)))),'[]'::jsonb),
      'participants',coalesce((select jsonb_agg(jsonb_build_object('id',ch.id,'state_id',ch.state_id,'name',ch.name,'surname',ch.surname,'gender',ch.gender,'age',ch.age,'race',rc.name,'race_id',ch.race_id) order by ch.state_id,ch.name)
        from fauxlore.state_characters ch left join fauxlore.map_categories rc on rc.layer='races' and rc.id=ch.race_id
        where ch.alive and ch.age>=16 and ch.gender in ('Мужской','Женский')
          and (exists(select 1 from fauxlore.account_states own where own.account_id=a.id and own.layer='states' and own.state_id=ch.state_id)
            or not exists(select 1 from fauxlore.account_states owned where owned.account_id=a.id and owned.layer='states' and owned.state_id=ch.state_id))
          and not exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and ch.id in(m.character_a_id,m.character_b_id))),'[]'::jsonb),
      'incoming',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'from_state_id',p.from_state_id,'from_state',fc.name,'to_state_id',p.to_state_id,'to_state',tc.name,
        'from_ruler',fa.name||' '||coalesce(fa.surname,''),'to_ruler',ta.name||' '||coalesce(ta.surname,''),'from_gender',fa.gender,'to_gender',ta.gender,'from_age',fa.age,'to_age',ta.age,
        'from_race',fr.name,'to_race',tr.name,'lawful_for_children',(fp.principles->>'authority'='Династия' and tp.principles->>'authority'='Династия'),
        'child_race',fauxlore.child_race_for_parents(fr.name,tr.name),'created_at',p.created_at) order by p.created_at desc)
        from fauxlore.state_marriage_proposals p join fauxlore.account_states ast on ast.state_id=p.to_state_id and ast.layer='states' and ast.account_id=a.id
        join fauxlore.map_categories fc on fc.layer='states' and fc.id=p.from_state_id join fauxlore.map_categories tc on tc.layer='states' and tc.id=p.to_state_id
        join fauxlore.state_profiles fp on fp.state_id=p.from_state_id join fauxlore.state_profiles tp on tp.state_id=p.to_state_id
        join fauxlore.state_characters fa on fa.id=p.from_character_id join fauxlore.state_characters ta on ta.id=p.to_character_id
        left join fauxlore.map_categories fr on fr.layer='races' and fr.id=fa.race_id left join fauxlore.map_categories tr on tr.layer='races' and tr.id=ta.race_id where p.status='pending'),'[]'::jsonb),
      'outgoing',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'from_state_id',p.from_state_id,'from_state',fc.name,'to_state_id',p.to_state_id,'to_state',tc.name,
        'from_ruler',fa.name||' '||coalesce(fa.surname,''),'to_ruler',ta.name||' '||coalesce(ta.surname,''),'from_gender',fa.gender,'to_gender',ta.gender,'from_age',fa.age,'to_age',ta.age,
        'from_race',fr.name,'to_race',tr.name,'lawful_for_children',(fp.principles->>'authority'='Династия' and tp.principles->>'authority'='Династия'),
        'child_race',fauxlore.child_race_for_parents(fr.name,tr.name),'created_at',p.created_at) order by p.created_at desc)
        from fauxlore.state_marriage_proposals p join fauxlore.account_states ast on ast.state_id=p.from_state_id and ast.layer='states' and ast.account_id=a.id
        join fauxlore.map_categories fc on fc.layer='states' and fc.id=p.from_state_id join fauxlore.map_categories tc on tc.layer='states' and tc.id=p.to_state_id
        join fauxlore.state_profiles fp on fp.state_id=p.from_state_id join fauxlore.state_profiles tp on tp.state_id=p.to_state_id
        join fauxlore.state_characters fa on fa.id=p.from_character_id join fauxlore.state_characters ta on ta.id=p.to_character_id
        left join fauxlore.map_categories fr on fr.layer='races' and fr.id=fa.race_id left join fauxlore.map_categories tr on tr.layer='races' and tr.id=ta.race_id where p.status='pending'),'[]'::jsonb));
  end if;
  if path='my/marriage-offers' and method='POST' then
    if body-'from_state_id'-'to_state_id'-'from_character_id'-'to_character_id'<>'{}' or
      coalesce(body->>'from_state_id','') !~ '^\d+$' or coalesce(body->>'to_state_id','') !~ '^\d+$' or
      coalesce(body->>'from_character_id','') !~ '^\d+$' or coalesce(body->>'to_character_id','') !~ '^\d+$' or request_id is null then
      raise sqlstate '22023' using message='Выберите оба государства и персонажей договора'; end if;
    from_state:=(body->>'from_state_id')::integer; to_state:=(body->>'to_state_id')::integer;
    if from_state=to_state or not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=from_state) then raise sqlstate '42501' using message='Нет доступа к отправляющему государству'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=dynastic_marriage_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into from_person from fauxlore.state_characters where id=(body->>'from_character_id')::bigint and state_id=from_state and alive and age>=16 and gender in ('Мужской','Женский') for update;
    select * into to_person from fauxlore.state_characters where id=(body->>'to_character_id')::bigint and state_id=to_state and alive and age>=16 and gender in ('Мужской','Женский') for update;
    if from_person.id is null or to_person.id is null then raise sqlstate '22023' using message='Один из персонажей недоступен: нужны живые совершеннолетние участники'; end if;
    if from_person.gender=to_person.gender then raise sqlstate '22023' using message='Для договора выберите персонажей противоположного пола'; end if;
    if exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and (from_person.id in(m.character_a_id,m.character_b_id) or to_person.id in(m.character_a_id,m.character_b_id))) then raise sqlstate '22023' using message='Один из персонажей уже состоит в браке'; end if;
    if not exists(select 1 from fauxlore.state_profiles where state_id=to_state) then raise sqlstate 'P0002' using message='Государство-получатель не найдено'; end if;
    insert into fauxlore.state_marriage_proposals(from_state_id,to_state_id,from_character_id,to_character_id,created_by)
      values(from_state,to_state,from_person.id,to_person.id,a.id) returning * into proposal;
    select * into from_profile from fauxlore.state_profiles where state_id=from_state;
    select * into to_profile from fauxlore.state_profiles where state_id=to_state;
    lawful:=(from_profile.principles->>'authority'='Династия' and to_profile.principles->>'authority'='Династия');
    select rc.name into from_race from fauxlore.map_categories rc where rc.layer='races' and rc.id=from_person.race_id;
    select rc.name into to_race from fauxlore.map_categories rc where rc.layer='races' and rc.id=to_person.race_id;
    child_race:=fauxlore.child_race_for_parents(from_race,to_race);
    male_age:=case when from_person.gender='Мужской' then from_person.age else to_person.age end;
    female_age:=case when from_person.gender='Женский' then from_person.age else to_person.age end;
    can_conceive:=child_race is not null and male_age<60 and female_age<45;
    result:=jsonb_build_object('proposal_id',proposal.id,'status',proposal.status,'lawful_for_children',lawful,'conception_possible',can_conceive,'child_race',child_race);
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'marriage','Предложен династический брак',(select name from fauxlore.map_categories where layer='states' and id=from_state)||' предлагает брак между персонажами '||from_person.name||' '||coalesce(from_person.surname,'')||' и '||to_person.name||' '||coalesce(to_person.surname,'')||'.'
      from fauxlore.account_states ast where ast.state_id=to_state and ast.layer='states'
      union select ac.id,'marriage','Предложен династический брак',(select name from fauxlore.map_categories where layer='states' and id=from_state)||' предлагает брак между персонажами '||from_person.name||' и '||to_person.name||'.'
        from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.state_id=to_state and ast.layer='states');
    return result;
  end if;
  if method='POST' and path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then
    proposal_id:=split_part(path,'/',3)::bigint; action:=split_part(path,'/',4);
    if body<>'{}' or request_id is null then raise sqlstate '22023' using message='Некорректная команда принятия предложения'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text); perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=dynastic_marriage_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into proposal from fauxlore.state_marriage_proposals where id=proposal_id and status='pending' for update;
    if not found then raise sqlstate 'P0002' using message='Предложение уже обработано или не найдено'; end if;
    if actor='admin' then actor_state:=proposal.to_state_id;
    else
      select ast.state_id into actor_state from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=proposal.to_state_id limit 1;
      if actor_state is null then raise sqlstate '42501' using message='Только принимающее государство может ответить на предложение'; end if;
    end if;
    if action='reject' then
      update fauxlore.state_marriage_proposals set status='declined',answered_at=now() where id=proposal.id;
      result:=jsonb_build_object('status','declined');
    else
      select * into from_person from fauxlore.state_characters where id=proposal.from_character_id and state_id=proposal.from_state_id and alive and age>=16 and gender in ('Мужской','Женский') for update;
      select * into to_person from fauxlore.state_characters where id=proposal.to_character_id and state_id=proposal.to_state_id and alive and age>=16 and gender in ('Мужской','Женский') for update;
      if from_person.id is null or to_person.id is null or from_person.gender=to_person.gender then raise sqlstate '22023' using message='Персонажи изменились; предложение больше нельзя принять'; end if;
      if exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and (from_person.id in(m.character_a_id,m.character_b_id) or to_person.id in(m.character_a_id,m.character_b_id))) then raise sqlstate '22023' using message='Один из персонажей уже состоит в браке'; end if;
      select * into from_profile from fauxlore.state_profiles where state_id=proposal.from_state_id;
      select * into to_profile from fauxlore.state_profiles where state_id=proposal.to_state_id;
      lawful:=(from_profile.principles->>'authority'='Династия' and to_profile.principles->>'authority'='Династия');
      select * into calendar_row from fauxlore.game_calendar where singleton=true;
      insert into fauxlore.state_marriages(character_a_id,character_b_id,marriage_type,lawful_for_a,lawful_for_b,started_at_turn)
        values(from_person.id,to_person.id,'dynastic',lawful,lawful,calendar_row.turn);
      update fauxlore.state_profiles set prestige=prestige+10 where state_id in(proposal.from_state_id,proposal.to_state_id);
      update fauxlore.state_marriage_proposals set status='accepted',answered_at=now() where id=proposal.id;
      result:=jsonb_build_object('status','accepted','lawful_for_dynasty',lawful,'prestige_awarded',10);
    end if;
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,request_id,fingerprint,result);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'marriage',case action when 'accept' then 'Династический брак заключён' else 'Предложение брака отклонено' end,
        case action when 'accept' then 'Предложение о браке между персонажами '||from_person.name||' '||coalesce(from_person.surname,'')||' и '||to_person.name||' '||coalesce(to_person.surname,'')||' принято. Участники получили по 10 ОП.' else 'Предложение о браке между персонажами '||from_person.name||' и '||to_person.name||' отклонено.' end
      from fauxlore.account_states ast where ast.state_id in(proposal.from_state_id,proposal.to_state_id) and ast.layer='states'
      union select ac.id,'marriage',case action when 'accept' then 'Династический брак заключён' else 'Предложение брака отклонено' end,
        case action when 'accept' then 'Предложение о браке принято; участники получили по 10 ОП.' else 'Предложение о браке отклонено.' end
        from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.state_id=proposal.to_state_id and ast.layer='states');
    return result;
  end if;
  raise sqlstate '22023' using message='Недопустимый запрос';
end $$;
revoke all on function fauxlore.dynastic_marriage_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.dynastic_marriage_api(text,text,jsonb,uuid) to authenticated;

create or replace function fauxlore.process_annual_births()
returns trigger language plpgsql security definer set search_path='' as $$
declare couple record; child_count integer; child_race integer; children_value jsonb; mother_death_chance numeric; mother_died boolean;
  child_index integer; is_lawful boolean; father_race text; mother_race text; authority_name text; birth_roll numeric;
begin
  if new.year=old.year then return new; end if;
  for couple in
    select mother.state_id,sp.principles,sp.official_race_id,sp.official_religion_id,
      father.id father_id,father.name father_name,father.surname father_surname,father.age father_age,father.race_id father_race_id,father.religion_id father_religion_id,
      mother.id mother_id,mother.name mother_name,mother.surname mother_surname,mother.age mother_age,mother.race_id mother_race_id,mother.religion_id mother_religion_id,
      case when m.character_a_id=mother.id then m.lawful_for_a else m.lawful_for_b end lawful_for_mother,
      coalesce(fr.name,'') father_race,coalesce(mr.name,'') mother_race
    from fauxlore.state_marriages m
    join fauxlore.state_characters a on a.id=m.character_a_id and a.alive
    join fauxlore.state_characters b on b.id=m.character_b_id and b.alive
    join fauxlore.state_characters father on father.id=case when a.gender='Мужской' then a.id else b.id end
    join fauxlore.state_characters mother on mother.id=case when a.gender='Женский' then a.id else b.id end
    join fauxlore.state_profiles sp on sp.state_id=mother.state_id
    left join fauxlore.map_categories fr on fr.layer='races' and fr.id=father.race_id
    left join fauxlore.map_categories mr on mr.layer='races' and mr.id=mother.race_id
    where m.ended_at_turn is null and a.gender<>b.gender and father.gender='Мужской' and father.age<60
      and mother.gender='Женский' and mother.age<45
  loop
    father_race:=couple.father_race; mother_race:=couple.mother_race;
    if father_race=mother_race and father_race in ('Люди','Эльфы','Дварфы','Зверолюди') then
      child_race:=case when father_race='Люди' then (select id from fauxlore.map_categories where layer='races' and name='Люди' limit 1)
        when father_race='Эльфы' then (select id from fauxlore.map_categories where layer='races' and name='Эльфы' limit 1)
        else couple.father_race_id end;
    elsif father_race in ('Люди','Эльфы','Полуэльфы') and mother_race in ('Люди','Эльфы','Полуэльфы') then
      child_race:=case when father_race='Люди' and mother_race='Люди' then (select id from fauxlore.map_categories where layer='races' and name='Люди' limit 1)
        when father_race='Эльфы' and mother_race='Эльфы' then (select id from fauxlore.map_categories where layer='races' and name='Эльфы' limit 1)
        else (select id from fauxlore.map_categories where layer='races' and name='Полуэльфы' limit 1) end;
    else continue; end if;
    if child_race is null or random()>=.25 then continue; end if;
    birth_roll:=random(); child_count:=case when birth_roll<.94 then 1 when birth_roll<.99 then 2 else 3 end;
    authority_name:=coalesce(couple.principles->>'authority',''); is_lawful:=authority_name='Династия' and couple.lawful_for_mother;
    children_value:='[]'::jsonb;
    for child_index in 1..child_count loop
      children_value:=children_value||jsonb_build_array(jsonb_build_object(
        'gender',case when random()<.5 then 'Мужской' else 'Женский' end,'race_id',child_race,
        'religion_id',case when random()<.5 then couple.father_religion_id else couple.mother_religion_id end,
        'legitimacy',case when authority_name='Династия' then case when is_lawful then 'Законный' else 'Незаконный' end else 'Неприменимо' end));
    end loop;
    mother_death_chance:=case when couple.mother_age<35 then .01 when couple.mother_age<40 then .03 else .07 end
      +case when child_count=2 then .02 when child_count=3 then .04 else 0 end;
    mother_death_chance:=least(.10,mother_death_chance); mother_died:=random()<mother_death_chance;
    insert into fauxlore.state_birth_events(state_id,year,turn,father_id,mother_id,children)
      values(couple.state_id,new.year,new.turn,couple.father_id,couple.mother_id,children_value);
    if mother_died then update fauxlore.state_characters set alive=false,died_at_turn=new.turn,is_current_ruler=false where id=couple.mother_id; end if;
    insert into fauxlore.notifications(account_id,kind,title,message)
      select recipients.account_id,'birth','Рождение в семье государства',
        'У '||couple.mother_name||' '||coalesce(couple.mother_surname,'')||' и '||couple.father_name||' '||coalesce(couple.father_surname,'')||' родилось детей: '||child_count||'. Откройте вкладку «Власть и династия», чтобы указать имена.'||case when mother_died then ' Мать детей умерла при родах.' else '' end
      from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=couple.state_id
        union select ac.id from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=couple.state_id)) recipients;
  end loop;
  return new;
end $$;
revoke all on function fauxlore.process_annual_births() from public,anon,authenticated;
