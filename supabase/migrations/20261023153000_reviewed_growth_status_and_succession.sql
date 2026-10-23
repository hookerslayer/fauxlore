-- Owner-approved population growth and group status loyalty.
do $$
declare fn text;
begin
  fn:=pg_get_functiondef('fauxlore.state_population_growth(integer)'::regprocedure);
  if position('p.population*.03*' in fn)=0 then raise exception 'Population indicator formula not found'; end if;
  execute replace(fn,'p.population*.03*','p.population*.015*');

  fn:=pg_get_functiondef('fauxlore.apply_turn_population_and_recruit_growth()'::regprocedure);
  if position('province_row.population*.03*' in fn)=0 then raise exception 'Population turn formula not found'; end if;
  execute replace(fn,'province_row.population*.03*','province_row.population*.015*');
end $$;

create or replace function fauxlore.group_status_loyalty_modifier(state_key integer,group_kind text,category_key integer)
returns numeric language sql stable security definer set search_path='' as $$
select case coalesce((select gp.status from fauxlore.state_group_politics gp where gp.state_id=state_key
  and gp.group_type=group_kind and gp.group_key=category_key::text),
  case when group_kind='race' and sp.official_race_id=category_key or group_kind='religion' and sp.official_religion_id=category_key then 'Официальная' else 'Невмешательство' end)
  when 'Официальная' then .10 when 'Признание' then .05 when 'Ассимиляция' then -.10 when 'Истребление' then -.25 else 0 end
from fauxlore.state_profiles sp where sp.state_id=state_key
$$;
revoke all on function fauxlore.group_status_loyalty_modifier(integer,text,integer) from public,anon,authenticated;

create or replace function fauxlore.apply_ruler_change_effects(target_state integer,new_race integer,new_religion integer)
returns void language plpgsql security definer set search_path='' as $$
declare old_race integer; old_religion integer;
begin
  select official_race_id,official_religion_id into old_race,old_religion
  from fauxlore.state_profiles where state_id=target_state for update;
  perform fauxlore.ensure_state_group_politics(target_state);
  update fauxlore.state_group_politics
    set loyalty=case when loyalty<.5 then least(.5,loyalty+.10) when loyalty>.5 then greatest(.5,loyalty-.10) else .5 end
    where state_id=target_state;
  if new_race is distinct from old_race then
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
      values(target_state,'race',old_race::text,'Признание')
      on conflict(state_id,group_type,group_key) do update set status='Признание';
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
      values(target_state,'race',new_race::text,'Официальная')
      on conflict(state_id,group_type,group_key) do update set status='Официальная';
  end if;
  if new_religion is distinct from old_religion then
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
      values(target_state,'religion',old_religion::text,'Признание')
      on conflict(state_id,group_type,group_key) do update set status='Признание';
    insert into fauxlore.state_group_politics(state_id,group_type,group_key,status)
      values(target_state,'religion',new_religion::text,'Официальная')
      on conflict(state_id,group_type,group_key) do update set status='Официальная';
  end if;
  update fauxlore.state_profiles set official_race_id=new_race,official_religion_id=new_religion
    where state_id=target_state;
end $$;
revoke all on function fauxlore.apply_ruler_change_effects(integer,integer,integer) from public,anon,authenticated;
notify pgrst,'reload schema';
