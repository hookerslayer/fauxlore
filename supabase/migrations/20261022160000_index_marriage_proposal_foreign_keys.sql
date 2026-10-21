create index if not exists state_marriage_proposals_from_state_idx
  on fauxlore.state_marriage_proposals(from_state_id);
create index if not exists state_marriage_proposals_to_state_idx
  on fauxlore.state_marriage_proposals(to_state_id);
create index if not exists state_marriage_proposals_from_character_idx
  on fauxlore.state_marriage_proposals(from_character_id);
create index if not exists state_marriage_proposals_to_character_idx
  on fauxlore.state_marriage_proposals(to_character_id);
create index if not exists state_marriage_proposals_created_by_idx
  on fauxlore.state_marriage_proposals(created_by);
