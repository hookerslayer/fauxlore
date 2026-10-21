create or replace function fauxlore.ensure_state_group_politics(target_state integer)
returns void language plpgsql security definer set search_path='' as $$
begin
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status,loyalty)
  select target_state,'estate',e.name,fauxlore.estate_status_for(target_state,e.name),
    case when e.name='Корона' then 1
      when fauxlore.estate_status_for(target_state,e.name)='Господствующее' then 1
      when fauxlore.estate_status_for(target_state,e.name)='Ключевое' then .8
      when fauxlore.estate_status_for(target_state,e.name)='Значимое' then .6
      when fauxlore.estate_status_for(target_state,e.name)='Бесправное' then .35 else .5 end
  from unnest(array['Корона','Знать','Духовенство','Горожане','Крестьяне']) e(name)
  on conflict(state_id,group_type,group_key) do update set status=excluded.status;
  insert into fauxlore.state_group_politics(state_id,group_type,group_key,status,loyalty)
  select distinct target_state,v.layer,v.category_id::text,
    case when v.layer='races' and v.category_id=sp.official_race_id then 'Официальная'
         when v.layer='religions' and v.category_id=sp.official_religion_id then 'Официальная' else 'Признание' end, .5
  from fauxlore.state_profiles sp
  join fauxlore.province_values sv on sv.layer='states' and sv.category_id=target_state
  join fauxlore.province_values v on v.province_id=sv.province_id and v.layer in ('races','religions')
  where sp.state_id=target_state
  on conflict(state_id,group_type,group_key) do update set status=excluded.status;
end $$;
revoke all on function fauxlore.ensure_state_group_politics(integer) from public,anon,authenticated;
notify pgrst,'reload schema';
