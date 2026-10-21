create or replace function fauxlore.end_regency_at_majority()
returns trigger language plpgsql security definer set search_path='' as $$
declare regent_row record;
begin
  if old.age>=16 or new.age<16 or not new.alive or not new.is_current_ruler then return new; end if;
  for regent_row in
    update fauxlore.state_characters set is_regent=false
    where state_id=new.state_id and is_regent and alive
    returning id,name,surname,state_id
  loop
    insert into fauxlore.notifications(account_id,kind,title,message)
    select recipients.account_id,'regency_end','Регентство завершено',
      'Правитель достиг совершеннолетия; регент '||regent_row.name||' '||regent_row.surname||' сложил полномочия.'
    from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=regent_row.state_id
      union select ac.id from fauxlore.accounts ac where ac.role='admin'
        and not exists(select 1 from fauxlore.account_states ast where ast.state_id=regent_row.state_id)) recipients;
  end loop;
  return new;
end $$;
revoke all on function fauxlore.end_regency_at_majority() from public,anon,authenticated;
create trigger state_character_end_regency_at_majority
after update of age on fauxlore.state_characters
for each row when (old.age<16 and new.age>=16 and new.is_current_ruler and new.alive)
execute function fauxlore.end_regency_at_majority();
