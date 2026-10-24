-- Decline stale pending offers that predate the new automatic rule.
do $$
declare proposal fauxlore.state_marriage_proposals;
begin
  for proposal in
    update fauxlore.state_marriage_proposals p
      set status='declined',answered_at=now()
      where p.status='pending' and exists(
        select 1 from fauxlore.state_marriages m
        where m.ended_at_turn is null and (
          p.from_character_id in(m.character_a_id,m.character_b_id)
          or p.to_character_id in(m.character_a_id,m.character_b_id)
        )
      )
      returning p.*
  loop
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct recipient.account_id,'marriage','Предложение брака отклонено',
        'Предложение династического брака автоматически отклонено: один из персонажей уже состоит в другом браке.'
      from (
        select ast.account_id from fauxlore.account_states ast
        where ast.layer='states' and ast.state_id in(proposal.from_state_id,proposal.to_state_id)
        union
        select ac.id from fauxlore.accounts ac
        where ac.role='admin' and exists(
          select 1 from fauxlore.state_profiles sp
          where sp.state_id in(proposal.from_state_id,proposal.to_state_id) and sp.is_npc
            and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=sp.state_id)
        )
      ) recipient;
  end loop;
end $$;
