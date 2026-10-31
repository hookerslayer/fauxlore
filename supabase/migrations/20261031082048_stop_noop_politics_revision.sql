-- Do not mutate political records or increment live_revision on a read when
-- the required rows and statuses already exist.
create or replace function fauxlore.ensure_state_group_politics(target_state integer)
returns void language plpgsql security definer set search_path='' as $function$
begin
  if exists (
    select 1 from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) e(name)
    left join fauxlore.state_group_politics g on g.state_id=target_state and g.group_type='estate' and g.group_key=e.name
    where g.state_id is null or g.status is distinct from fauxlore.estate_status_for(target_state,e.name)
  ) then
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
    select target_state,'estate',e.name,fauxlore.estate_status_for(target_state,e.name)
    from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) e(name)
    on conflict(state_id,group_type,group_key) do update set status=excluded.status
      where fauxlore.state_group_politics.status is distinct from excluded.status;
  end if;
  if exists (
    select 1 from fauxlore.state_profiles sp
    join fauxlore.province_values sv on sv.layer='states' and sv.category_id=target_state
    join fauxlore.province_values v on v.province_id=sv.province_id and v.layer in ('races','religions')
    where sp.state_id=target_state and not exists (
      select 1 from fauxlore.state_group_politics g where g.state_id=target_state
      and g.group_type=case v.layer when 'races' then 'race' else 'religion' end
      and g.group_key=v.category_id::text)
  ) then
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
    select distinct target_state,case v.layer when 'races' then 'race' else 'religion' end,v.category_id::text,
      case when v.layer='races' and v.category_id=sp.official_race_id then 'Официальная'
           when v.layer='religions' and v.category_id=sp.official_religion_id then 'Официальная'
           else 'Невмешательство' end
    from fauxlore.state_profiles sp
    join fauxlore.province_values sv on sv.layer='states' and sv.category_id=target_state
    join fauxlore.province_values v on v.province_id=sv.province_id and v.layer in ('races','religions')
    where sp.state_id=target_state
    on conflict(state_id,group_type,group_key) do nothing;
  end if;
end
$function$;
notify pgrst,'reload schema';
