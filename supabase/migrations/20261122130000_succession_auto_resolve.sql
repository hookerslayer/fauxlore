-- Если выборы не завершены к resolves_turn, они проводятся автоматически:
-- побеждает кандидат с наибольшей поддержкой; престиж падает до 0,
-- ключевые сословия теряют 5 п.п. лояльности.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch succession outside production candidate';
  end if;
end
$guard$;

create or replace function fauxlore.install_succession_candidate(event_id bigint)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare event_row record; candidate jsonb; new_character fauxlore.state_characters;
  key_estate text; support_flag boolean; auto_chosen boolean:=false;
begin
  select * into event_row from fauxlore.state_succession_events
  where id=event_id and resolved_at is null for update;
  if not found then return; end if;

  candidate:=event_row.chosen_candidate;
  if candidate is null then
    select value into candidate
    from jsonb_array_elements(event_row.candidates) value
    order by coalesce((value->>'support_weight')::numeric,0) desc,
             coalesce((value->>'slot')::int,0)
    limit 1;
    if candidate is null then return; end if;
    auto_chosen:=true;
    update fauxlore.state_succession_events
      set chosen_candidate=candidate, chosen_at=now()
      where id=event_row.id;
  end if;

  update fauxlore.state_characters set is_current_ruler=false
  where state_id=event_row.state_id and is_current_ruler;

  insert into fauxlore.state_characters(state_id,name,surname,gender,age,race_id,religion_id,is_current_ruler)
  values(event_row.state_id,candidate->>'name',candidate->>'surname',candidate->>'gender',
    (candidate->>'age')::smallint,(candidate->>'race_id')::integer,(candidate->>'religion_id')::integer,true)
  returning * into new_character;

  perform fauxlore.apply_ruler_change_effects(event_row.state_id,new_character.race_id,new_character.religion_id);

  update fauxlore.state_profiles
  set prestige=case when auto_chosen then 0 else 10 end,
      ruler_name=new_character.name,ruler_surname=new_character.surname,ruler_gender=new_character.gender,
      ruler_title=new_character.title,ruler_age=new_character.age,
      term_started_turn=(select turn from fauxlore.game_calendar where singleton),
      designated_heir_id=null,designated_successor_id=null
  where state_id=event_row.state_id;

  if auto_chosen then
    update fauxlore.state_group_politics
    set recovery_target=loyalty,loyalty=greatest(0,loyalty-.05)
    where state_id=event_row.state_id and status='Ключевое';
  end if;

  if event_row.event_type='dynastic_candidates' and jsonb_typeof(candidate->'support')='object' then
    for key_estate,support_flag in select key,value::text::boolean from jsonb_each(candidate->'support') loop
      if not support_flag then
        update fauxlore.state_group_politics
        set recovery_target=loyalty,loyalty=greatest(0,loyalty-.20)
        where state_id=event_row.state_id and group_type='estate' and group_key=key_estate;
      end if;
    end loop;
  end if;

  update fauxlore.state_succession_events set resolved_at=now() where id=event_row.id;

  insert into fauxlore.notifications(account_id,kind,title,message)
  select recipients.account_id,'succession',
    case when auto_chosen then 'Выборы прошли без вашего участия' else 'Вступил новый правитель' end,
    case when auto_chosen
      then 'Кандидат не был выбран. Победил '||new_character.name||' '||new_character.surname||
        ' — кандидат с наибольшей поддержкой. Престиж снижен до 0 ОП, ключевые сословия потеряли 5 п.п. лояльности.'
      else 'Правителем стал(а) '||new_character.name||' '||new_character.surname||
        '. Престиж установлен на 10 ОП; лояльность групп скорректирована.' end
  from (select distinct ast.account_id from fauxlore.account_states ast
        where ast.layer='states' and ast.state_id=event_row.state_id
        union
        select ac.id from fauxlore.accounts ac where ac.role='admin'
          and not exists(select 1 from fauxlore.account_states ast where ast.state_id=event_row.state_id)) recipients;
end
$function$;

create or replace function fauxlore.resolve_ruler_succession()
returns trigger language plpgsql security definer set search_path='' as $function$
declare event_row record;
begin
  if new.turn=old.turn then return new; end if;
  for event_row in
    select id from fauxlore.state_succession_events
    where resolved_at is null and resolves_turn<=new.turn
    for update
  loop
    perform fauxlore.install_succession_candidate(event_row.id);
  end loop;
  return new;
end $function$;

-- Разрешить уже зависшие выборы (в частности, Рейксманн, ход 6).
do $repair$
declare event_row record;
begin
  for event_row in
    select e.id from fauxlore.state_succession_events e
    cross join fauxlore.game_calendar c
    where e.resolved_at is null and e.resolves_turn<=c.turn
  loop
    perform fauxlore.install_succession_candidate(event_row.id);
  end loop;
end
$repair$;
