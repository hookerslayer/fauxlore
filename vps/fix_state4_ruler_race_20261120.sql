-- Правитель Республики Кайрнхольм (state_id=4) переводится в расу Дварфы.
-- Религия и имя сохраняются; официальная раса государства уже Дварфы.
begin;
do $fix$
declare changed integer;
begin
  update fauxlore.state_characters set race_id=2
    where state_id=4 and is_current_ruler and alive and race_id<>2;
  get diagnostics changed=row_count;
  if changed=0 and not exists(select 1 from fauxlore.state_characters where state_id=4 and is_current_ruler and alive and race_id=2) then
    raise exception 'Действующий правитель государства 4 не найден';
  end if;
  raise notice 'Правитель переведён в расу Дварфы: % строк',changed;
end $fix$;
commit;

select c.id,c.name,c.surname,c.race_id,r.name as race,c.religion_id,rel.name as religion,c.is_current_ruler
from fauxlore.state_characters c
left join fauxlore.map_categories r on r.layer='races' and r.id=c.race_id
left join fauxlore.map_categories rel on rel.layer='religions' and rel.id=c.religion_id
where c.state_id=4 and c.is_current_ruler;
