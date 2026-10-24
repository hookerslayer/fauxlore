-- Auto-decline outstanding offers when a participant enters a local marriage.
create or replace function fauxlore.decline_stale_marriage_proposals()
returns trigger language plpgsql security definer set search_path='' as $$
declare proposal fauxlore.state_marriage_proposals; message_value text;
begin
  if new.marriage_type<>'local' then return new; end if;
  message_value:='Предложение династического брака автоматически отклонено: один из персонажей уже вступил в другой брак.';
  for proposal in
    update fauxlore.state_marriage_proposals p
      set status='declined',answered_at=now()
      where p.status='pending' and (
        p.from_character_id in(new.character_a_id,new.character_b_id)
        or p.to_character_id in(new.character_a_id,new.character_b_id)
      )
      returning p.*
  loop
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct recipient.account_id,'marriage','Предложение брака отклонено',message_value
      from (
        select ast.account_id
        from fauxlore.account_states ast
        where ast.layer='states' and ast.state_id in(proposal.from_state_id,proposal.to_state_id)
        union
        select ac.id
        from fauxlore.accounts ac
        where ac.role='admin' and exists(
          select 1 from fauxlore.state_profiles sp
          where sp.state_id in(proposal.from_state_id,proposal.to_state_id) and sp.is_npc
            and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=sp.state_id)
        )
      ) recipient;
  end loop;
  return new;
end $$;
revoke all on function fauxlore.decline_stale_marriage_proposals() from public,anon,authenticated;
drop trigger if exists state_marriage_decline_stale_proposals on fauxlore.state_marriages;
create trigger state_marriage_decline_stale_proposals after insert on fauxlore.state_marriages
for each row execute function fauxlore.decline_stale_marriage_proposals();
