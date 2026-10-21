create or replace function fauxlore.resolve_designated_dictator()
returns trigger language plpgsql security definer set search_path='' as $$
declare event_row fauxlore.state_succession_events; sp fauxlore.state_profiles; designee fauxlore.state_characters;
  candidate jsonb; total_key_weight numeric; support_weight numeric; is_supported boolean;
begin
  if not old.alive or new.alive or not old.is_current_ruler then return new; end if;
  select * into sp from fauxlore.state_profiles where state_id=old.state_id and principles->>'authority'='Диктат' and designated_successor_id is not null;
  if not found then return new; end if;
  select * into designee from fauxlore.state_characters where id=sp.designated_successor_id and state_id=old.state_id and alive and age>=16;
  if not found then return new; end if;
  select * into event_row from fauxlore.state_succession_events where state_id=old.state_id and resolved_at is null order by id desc limit 1 for update;
  if not found then return new; end if;
  candidate:=event_row.candidates->0;
  candidate:=candidate||jsonb_build_object('name',designee.name,'surname',designee.surname,'gender',designee.gender,'age',designee.age,
    'race_id',designee.race_id,'religion_id',designee.religion_id,'race',(select name from fauxlore.map_categories where layer='races' and id=designee.race_id),
    'religion',(select name from fauxlore.map_categories where layer='religions' and id=designee.religion_id),'designated',true);
  update fauxlore.state_succession_events set candidates=jsonb_set(candidates,'{0}',candidate,true) where id=event_row.id returning * into event_row;
  select coalesce(sum(fauxlore.province_value_for_state(p.id,old.state_id)),0) into total_key_weight
    from fauxlore.province_values s join fauxlore.provinces p on p.id=s.province_id and p.kind='land'
    where s.layer='states' and s.category_id=old.state_id and fauxlore.estate_status_for(old.state_id,p.belonging)='Ключевое';
  support_weight:=coalesce((candidate->>'support_weight')::numeric,0);
  is_supported:=total_key_weight>0 and support_weight>total_key_weight/2;
  if not is_supported then return new; end if;
  update fauxlore.state_characters set is_current_ruler=false where state_id=old.state_id and is_current_ruler;
  update fauxlore.state_characters set is_current_ruler=true where id=designee.id;
  perform fauxlore.apply_ruler_change_effects(old.state_id,designee.race_id,designee.religion_id);
  update fauxlore.state_profiles set prestige=10,ruler_name=designee.name,ruler_surname=designee.surname,ruler_gender=designee.gender,
    ruler_title=designee.title,ruler_age=designee.age,official_race_id=designee.race_id,official_religion_id=designee.religion_id,
    term_started_turn=(select turn from fauxlore.game_calendar where singleton),designated_heir_id=null,designated_successor_id=null where state_id=old.state_id;
  update fauxlore.state_succession_events set chosen_candidate=candidate,chosen_at=now(),resolved_at=now() where id=event_row.id;
  update fauxlore.notifications n set title='Назначенный преемник вступил во власть',message=designee.name||' '||designee.surname||' получил(а) поддержку большинства влияния ключевых сословий и немедленно вступил(а) в должность.'
    where n.kind='succession' and n.title='Требуется передача власти' and n.created_at>now()-interval '1 minute'
      and n.account_id in (
        select ast.account_id from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id
        union select ac.id from fauxlore.accounts ac where ac.role='admin'
          and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=old.state_id)
      );
  return new;
end $$;
revoke all on function fauxlore.resolve_designated_dictator() from public,anon,authenticated;
