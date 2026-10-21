create or replace function fauxlore.state_characters_payload(target_state_id integer)
returns jsonb language sql security definer set search_path='' as $$
  with ruler as (
    select ch.* from fauxlore.state_characters ch
    where ch.state_id=target_state_id and (ch.is_current_ruler or not exists(
      select 1 from fauxlore.state_characters active where active.state_id=target_state_id and active.is_current_ruler))
    order by ch.is_current_ruler desc,ch.id desc limit 1
  ), relevant as (
    select distinct ch.*,
      case
        when ch.is_current_ruler then 'Правитель'
        when exists(select 1 from fauxlore.state_marriages m where
          ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler)) or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
          then case when exists(select 1 from fauxlore.state_marriages m where m.ended_at_turn is null and
            ((m.character_a_id=ch.id and m.character_b_id=(select id from ruler)) or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler))))
            then case when ch.gender='Женский' then 'Супруга' else 'Супруг' end else 'Бывший супруг' end
        when ch.id in ((select father_id from ruler),(select mother_id from ruler)) then 'Родитель'
        when (select id from ruler) in (ch.father_id,ch.mother_id) then 'Ребёнок'
        when exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
          and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id)) or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))) then 'Брат/сестра'
        else 'Родственник'
      end as relation
    from fauxlore.state_characters ch
    where ch.state_id=target_state_id and (ch.is_current_ruler or ch.id in ((select father_id from ruler),(select mother_id from ruler))
      or (select id from ruler) in (ch.father_id,ch.mother_id)
      or exists(select 1 from fauxlore.state_marriages m where (m.character_a_id=ch.id and m.character_b_id=(select id from ruler))
        or (m.character_b_id=ch.id and m.character_a_id=(select id from ruler)))
      or exists(select 1 from fauxlore.state_characters rr where rr.id=(select id from ruler)
        and ((rr.father_id is not null and rr.father_id in (ch.father_id,ch.mother_id)) or (rr.mother_id is not null and rr.mother_id in (ch.father_id,ch.mother_id)))))
    union
    select ch.*,case when ch.gender='Женский' then 'Супруга' else 'Супруг' end as relation
    from fauxlore.state_marriages m
    join fauxlore.state_characters ch on ch.id=case when m.character_a_id=(select id from ruler) then m.character_b_id else m.character_a_id end
    where (m.character_a_id=(select id from ruler) or m.character_b_id=(select id from ruler)) and ch.state_id<>target_state_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'name',r.name,'surname',r.surname,'gender',r.gender,'title',r.title,'age',r.age,'race_id',r.race_id,'religion_id',r.religion_id,
    'race',(select c.name from fauxlore.map_categories c where c.layer='races' and c.id=r.race_id),
    'religion',(select c.name from fauxlore.map_categories c where c.layer='religions' and c.id=r.religion_id),
    'alive',r.alive,'legitimacy',r.legitimacy,'is_current_ruler',r.is_current_ruler,'is_regent',r.is_regent,'relationship',r.relation,
    'state_name',(select c.name from fauxlore.map_categories c where c.layer='states' and c.id=r.state_id)
  ) order by r.is_current_ruler desc,r.age desc,r.id),'[]'::jsonb) from relevant r
$$;

create or replace function fauxlore.turn_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; calendar_row fauxlore.game_calendar; previous fauxlore.operations;
  fingerprint text; result jsonb; report_value jsonb; character_row record;
  age_value integer; death_chance numeric; died boolean; dead_ruler_count integer:=0; advanced_character_count integer:=0;
begin
  if path='game/calendar' and method='GET' then
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    return jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn);
  end if;
  if path<>'admin/turn/advance' or method<>'POST' or body-array['expected_year','expected_turn','report']<>'{}' or
    jsonb_typeof(body->'report') is distinct from 'array' or octet_length(coalesce(body->'report','[]'::jsonb)::text)>1500000 then
    raise sqlstate '22023' using message='Некорректный запрос смены хода'; end if;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=turn_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true for update;
  if calendar_row.year<>(body->>'expected_year')::integer or calendar_row.turn<>(body->>'expected_turn')::integer then
    raise sqlstate '40001' using message='Ход уже изменён в другой сессии. Обновите страницу и повторите.'; end if;
  report_value:=body->'report';
  insert into fauxlore.turn_economy_reports(year,turn,report,created_by) values(calendar_row.year,calendar_row.turn,report_value,a.id);
  for character_row in
    select ch.id,ch.state_id,ch.age,ch.name,ch.surname,ch.is_current_ruler,coalesce(rc.name,'') as race_name
    from fauxlore.state_characters ch left join fauxlore.map_categories rc on rc.layer='races' and rc.id=ch.race_id
    where ch.alive order by ch.id for update of ch
  loop
    age_value:=least(250,character_row.age+1);
    death_chance:=case
      when character_row.race_name in ('Люди','Полуэльфы','Зверолюди') then
        case when age_value<60 then 0 when age_value<=70 then .05 when age_value<=80 then .15 when age_value<=90 then .25 when age_value<=100 then .50 else .70 end
      when character_row.race_name='Дварфы' then
        case when age_value<80 then 0 when age_value<=90 then .05 when age_value<=100 then .15 when age_value<=110 then .25 when age_value<=120 then .50 else .70 end
      when character_row.race_name='Эльфы' then
        case when age_value<100 then 0 when age_value<=120 then .05 when age_value<=140 then .15 when age_value<=160 then .25 when age_value<=180 then .50 else .70 end
      else 0 end;
    died:=death_chance>0 and random()<death_chance;
    update fauxlore.state_characters set age=age_value,alive=not died,
      died_at_turn=case when died then calendar_row.turn else died_at_turn end,
      is_current_ruler=case when died and character_row.is_current_ruler then false else is_current_ruler end
    where id=character_row.id;
    advanced_character_count:=advanced_character_count+1;
    if died and character_row.is_current_ruler then
      dead_ruler_count:=dead_ruler_count+1;
      insert into fauxlore.notifications(account_id,kind,title,message)
      select recipients.account_id,'ruler_death','Умер правитель государства',
        'Правитель '||trim(character_row.name||' '||character_row.surname)||' умер в возрасте '||age_value||' лет. Требуется провести передачу власти.'
      from (
        select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=character_row.state_id
        union
        select ac.id from fauxlore.accounts ac where ac.role='admin'
          and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=character_row.state_id)
      ) recipients;
    end if;
  end loop;
  update fauxlore.game_calendar set year=year+1,turn=turn+1,updated_at=now() where singleton=true returning * into calendar_row;
  result:=jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn,
    'calculated_year',calendar_row.year-1,'calculated_turn',calendar_row.turn-1,'states_calculated',jsonb_array_length(report_value),
    'characters_aged',advanced_character_count,'rulers_died',dead_ruler_count);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,turn_api.request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.turn_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.turn_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
