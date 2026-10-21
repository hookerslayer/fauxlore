create or replace function fauxlore.end_marriage_when_character_dies()
returns trigger language plpgsql security definer set search_path='' as $$
declare current_turn integer;
begin
  if not old.alive or new.alive then return new; end if;
  select turn into current_turn from fauxlore.game_calendar where singleton=true;
  update fauxlore.state_marriages
    set ended_at_turn=coalesce(current_turn,started_at_turn)
    where ended_at_turn is null and new.id in(character_a_id,character_b_id);
  return new;
end $$;
revoke all on function fauxlore.end_marriage_when_character_dies() from public,anon,authenticated;
drop trigger if exists state_character_end_marriage_on_death on fauxlore.state_characters;
create trigger state_character_end_marriage_on_death after update of alive on fauxlore.state_characters
for each row when(old.alive and not new.alive) execute function fauxlore.end_marriage_when_character_dies();

update fauxlore.state_marriages m
  set ended_at_turn=coalesce((select turn from fauxlore.game_calendar where singleton=true),m.started_at_turn)
  where m.ended_at_turn is null and exists(
    select 1 from fauxlore.state_characters ch
    where ch.id in(m.character_a_id,m.character_b_id) and not ch.alive
  );
