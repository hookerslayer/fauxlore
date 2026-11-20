-- Восстановление официальной расы Республики Кайрнхольм (state_id=4).
-- Причина: выборы 7 ноября 2026 поставили правителем эльфа Аэлена Тихолиста;
-- по правилу смены правителя его раса стала официальной, хотя всё население
-- государства — Дварфы. Владелец решил вернуть Дварфов и сохранить правителя.
-- Скрипт идемпотентен: повторный запуск ничего не меняет.
begin;

do $fix$
declare old_race integer;
begin
  select official_race_id into old_race from fauxlore.state_profiles where state_id=4 for update;
  if old_race is null then raise exception 'Государство 4 не найдено'; end if;
  if old_race=2 then
    raise notice 'Официальная раса уже Дварфы';
    return;
  end if;

  update fauxlore.state_profiles set official_race_id=2 where state_id=4;

  -- ensure_state_group_politics выставляет официальную группу по профилю,
  -- поэтому вызываем его после смены расы и лишь затем правим статусы.
  perform fauxlore.ensure_state_group_politics(4);
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
    values(4,'race','3','Признание')
    on conflict(state_id,group_type,group_key) do update set status='Признание';
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
    values(4,'race','2','Официальная')
    on conflict(state_id,group_type,group_key) do update set status='Официальная';

  insert into fauxlore.notifications(account_id,kind,title,message)
    select a.id,'succession','Официальная раса восстановлена',
      'Администратор вернул государству официальную расу — Дварфы. Правитель Аэлен Тихолист сохраняет должность; Эльфы получили статус «Признание».'
    from fauxlore.account_states s join fauxlore.accounts a on a.id=s.account_id
    where s.state_id=4 and s.layer='states'
      and not exists(select 1 from fauxlore.notifications n
        where n.account_id=a.id and n.title='Официальная раса восстановлена' and n.created_at::date=current_date);

  raise notice 'Официальная раса переключена на Дварфов';
end $fix$;

commit;

select sp.state_id,sp.official_race_id,r.name as race,sp.official_religion_id,rel.name as religion
from fauxlore.state_profiles sp
left join fauxlore.map_categories r on r.layer='races' and r.id=sp.official_race_id
left join fauxlore.map_categories rel on rel.layer='religions' and rel.id=sp.official_religion_id
where sp.state_id=4;

select group_key,status from fauxlore.state_group_politics
where state_id=4 and group_type='race' order by group_key;
