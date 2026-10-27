-- Avoid ambiguity between the province id argument and province_values.province_id.
create or replace function fauxlore.set_province_assimilation(province_id integer,payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
#variable_conflict use_variable
declare actor fauxlore.accounts; province_row fauxlore.provinces; state_id integer;
  official_race integer; official_religion integer; race_id integer; religion_id integer;
  race_turns integer; religion_turns integer;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' then raise sqlstate '42501' using message='Изменять срок ассимиляции может только администратор'; end if;
  if jsonb_typeof(payload) is distinct from 'object' or payload-array['race_turns','religion_turns']<>'{}'::jsonb
    or not(payload?'race_turns') or not(payload?'religion_turns') then
    raise sqlstate '22023' using message='Укажите сроки ассимиляции расы и религии'; end if;
  select * into province_row from fauxlore.provinces where id=province_id and kind='land' for update;
  if not found then raise sqlstate 'P0002' using message='Сухопутная провинция не найдена'; end if;
  select owner.category_id,sp.official_race_id,sp.official_religion_id,race.category_id,religion.category_id
    into state_id,official_race,official_religion,race_id,religion_id
  from fauxlore.province_values owner join fauxlore.state_profiles sp on sp.state_id=owner.category_id
  left join fauxlore.province_values race on race.province_id=province_id and race.layer='races'
  left join fauxlore.province_values religion on religion.province_id=province_id and religion.layer='religions'
  where owner.province_id=province_id and owner.layer='states';
  if not found then raise sqlstate '22023' using message='Провинция должна принадлежать государству'; end if;
  if jsonb_typeof(payload->'race_turns') not in ('number','null') or jsonb_typeof(payload->'religion_turns') not in ('number','null') then
    raise sqlstate '22023' using message='Срок должен быть целым числом от 0 до 300'; end if;
  race_turns:=case when payload->'race_turns'='null'::jsonb then 0 else (payload->>'race_turns')::integer end;
  religion_turns:=case when payload->'religion_turns'='null'::jsonb then 0 else (payload->>'religion_turns')::integer end;
  if race_turns not between 0 and 300 or religion_turns not between 0 and 300 then
    raise sqlstate '22023' using message='Срок должен быть целым числом от 0 до 300'; end if;
  if race_turns>0 and (race_id is null or race_id=official_race) then raise sqlstate '22023' using message='В этой провинции нет расы для ассимиляции'; end if;
  if religion_turns>0 and (religion_id is null or religion_id=official_religion) then raise sqlstate '22023' using message='В этой провинции нет религии для ассимиляции'; end if;
  update fauxlore.provinces set
    race_assimilation_turns=nullif(race_turns,0),race_assimilation_target_id=case when race_turns>0 then official_race else null end,
    religion_assimilation_turns=nullif(religion_turns,0),religion_assimilation_target_id=case when religion_turns>0 then official_religion else null end
  where id=province_id returning * into province_row;
  return to_jsonb(province_row);
end
$function$;
revoke all on function fauxlore.set_province_assimilation(integer,jsonb) from public,anon,authenticated;
