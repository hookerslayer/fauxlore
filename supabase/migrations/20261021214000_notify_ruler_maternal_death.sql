create or replace function fauxlore.notify_ruler_maternal_death()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.alive and not new.alive and old.is_current_ruler and exists(
    select 1 from fauxlore.state_birth_events e
    join fauxlore.game_calendar c on c.singleton=true and c.year=e.year
    where e.state_id=new.state_id and e.mother_id=new.id
  ) then
    insert into fauxlore.notifications(account_id,kind,title,message)
    select recipients.account_id,'ruler_death','Правительница умерла при родах',
      'Правительница умерла при родах. Требуется передача власти согласно принципу государства.'
    from (select distinct ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=new.state_id
      union select ac.id from fauxlore.accounts ac where ac.role='admin' and not exists(
        select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=new.state_id)) recipients;
  end if;
  return new;
end $$;
revoke all on function fauxlore.notify_ruler_maternal_death() from public,anon,authenticated;
drop trigger if exists state_characters_notify_maternal_ruler_death on fauxlore.state_characters;
create trigger state_characters_notify_maternal_ruler_death after update of alive on fauxlore.state_characters
for each row execute function fauxlore.notify_ruler_maternal_death();
notify pgrst,'reload schema';
