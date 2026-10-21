create or replace function fauxlore.prepare_local_marriage_candidate()
returns trigger language plpgsql security definer set search_path='' as $$
declare generated jsonb; sp fauxlore.state_profiles; estate_name text; options text[]; selected_estate text;
  total_weight numeric:=0; estate_weight numeric; roll numeric; cumulative numeric:=0;
begin
  generated:=fauxlore.generate_character_name(new.race_id,new.gender);
  new.name:=generated->>'name'; new.surname:=generated->>'surname';
  select * into sp from fauxlore.state_profiles where state_id=new.state_id;
  options:=array(select x.estate from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) as x(estate) where fauxlore.estate_status_for(new.state_id,x.estate)='Ключевое');
  foreach estate_name in array options loop
    select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id)),0) into estate_weight
    from fauxlore.province_values sv join fauxlore.provinces p on p.id=sv.province_id and p.kind='land'
    where sv.layer='states' and sv.category_id=new.state_id and p.belonging=estate_name;
    total_weight:=total_weight+greatest(estate_weight,0);
  end loop;
  if cardinality(options)>0 then
    if total_weight<=0 then total_weight:=cardinality(options); roll:=random()*total_weight;
    else roll:=random()*total_weight; end if;
    foreach estate_name in array options loop
      select coalesce(sum(fauxlore.province_value_for_state(p.id,new.state_id)),0) into estate_weight
      from fauxlore.province_values sv join fauxlore.provinces p on p.id=sv.province_id and p.kind='land'
      where sv.layer='states' and sv.category_id=new.state_id and p.belonging=estate_name;
      if estate_weight<=0 and total_weight=cardinality(options) then estate_weight:=1; end if;
      cumulative:=cumulative+greatest(estate_weight,0);
      if roll<cumulative then selected_estate:=estate_name; exit; end if;
    end loop;
  end if;
  new.supported_by:=case when selected_estate is null then '{}'::text[] else array[selected_estate] end;
  return new;
end $$;
revoke all on function fauxlore.prepare_local_marriage_candidate() from public,anon,authenticated;
drop trigger if exists state_marriage_candidate_prepare on fauxlore.state_marriage_candidates;
create trigger state_marriage_candidate_prepare before insert on fauxlore.state_marriage_candidates
for each row execute function fauxlore.prepare_local_marriage_candidate();
notify pgrst,'reload schema';
