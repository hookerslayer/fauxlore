create or replace function fauxlore.generate_character_name(target_race integer,target_gender text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare race_name text; given_names text[]; family_names text[]; given_name text; family_name text;
begin
  select name into race_name from fauxlore.map_categories where layer='races' and id=target_race;
  if race_name='Дварфы' then
    given_names:=case when target_gender='Женский' then array['Дис','Хильда','Фрея','Бринна','Гудрун','Сигрид'] else array['Балин','Борин','Дурин','Гимли','Торин','Фарин'] end;
    family_names:=array['Меднобород','Каменорук','Железный Щит','Глубинный','Рунный Молот'];
  elsif race_name='Эльфы' then
    given_names:=case when target_gender='Женский' then array['Ариэн','Лиандра','Элэна','Фаэлин','Мириэль','Сильвэ'] else array['Аэлен','Фаэран','Элрон','Лаэрион','Таланиэль','Тирион'] end;
    family_names:=array['Тихолист','Серебряная Ветвь','Звёздный Предел','Сумеречный Ручей','Лунный Цвет'];
  elsif race_name='Полуэльфы' then
    given_names:=case when target_gender='Женский' then array['Элина','Мираэль','Нария','Лиора','Велена','Саэль'] else array['Арен','Дамир','Илар','Ренар','Тарен','Элиан'] end;
    family_names:=array['Смешанная Ветвь','Полуночный','Серый Рассвет','Двухкровный','Лесной Путь'];
  elsif race_name='Зверолюди' then
    given_names:=case when target_gender='Женский' then array['Ликана','Рысья','Шайра','Волана','Тигра','Сайла'] else array['Рыкор','Волк','Шархан','Клык','Бархан','Тарг'] end;
    family_names:=array['Серый Клык','Быстрая Лапа','Дальняя Тропа','Полосатая Грива','Лунный След'];
  else
    given_names:=case when target_gender='Женский' then array['Алиса','Велена','Дарья','Елена','Ирина','Лада','Мира','Надежда','Рада','Ярослава'] else array['Алексей','Борис','Владимир','Глеб','Дамир','Илья','Мирослав','Ратибор','Святослав','Яромир'] end;
    family_names:=array['Белоярский','Ветров','Зорин','Каменев','Лесной','Руднев','Серебряков','Сумеречный'];
  end if;
  given_name:=given_names[1+floor(random()*cardinality(given_names))::integer];
  family_name:=family_names[1+floor(random()*cardinality(family_names))::integer];
  return jsonb_build_object('name',given_name,'surname',family_name);
end $$;
revoke all on function fauxlore.generate_character_name(integer,text) from public,anon,authenticated;

create or replace function fauxlore.apply_race_specific_succession_names()
returns trigger language plpgsql security definer set search_path='' as $$
declare result jsonb; i integer; person jsonb; updated jsonb:='[]'::jsonb;
begin
  for i in 0..jsonb_array_length(new.candidates)-1 loop
    person:=new.candidates->i;
    result:=fauxlore.generate_character_name((person->>'race_id')::integer,person->>'gender');
    person:=person||result;
    updated:=updated||jsonb_build_array(person);
  end loop;
  new.candidates:=updated;
  return new;
end $$;
revoke all on function fauxlore.apply_race_specific_succession_names() from public,anon,authenticated;
drop trigger if exists state_succession_race_names on fauxlore.state_succession_events;
create trigger state_succession_race_names before insert on fauxlore.state_succession_events
for each row execute function fauxlore.apply_race_specific_succession_names();

create or replace function fauxlore.apply_race_specific_regent_names()
returns trigger language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if new.is_regent then
    result:=fauxlore.generate_character_name(new.race_id,new.gender);
    new.name:=result->>'name'; new.surname:=result->>'surname';
  end if;
  return new;
end $$;
revoke all on function fauxlore.apply_race_specific_regent_names() from public,anon,authenticated;
drop trigger if exists state_character_race_names on fauxlore.state_characters;
create trigger state_character_race_names before insert on fauxlore.state_characters
for each row when(new.is_regent) execute function fauxlore.apply_race_specific_regent_names();
notify pgrst,'reload schema';
