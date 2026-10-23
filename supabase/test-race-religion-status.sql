-- Operator-only status API check. The test edits a temporary province mapping
-- and a status inside one transaction, then rolls back all fixture changes.
begin;
do $$
declare admin_uid uuid; sid integer; official_race integer; province_key integer; other_race integer;
  command_id uuid:=gen_random_uuid(); response jsonb; repeated jsonb; politics jsonb;
begin
  select auth_user_id into admin_uid from fauxlore.accounts where role='admin' and auth_user_id is not null limit 1;
  if admin_uid is null then raise exception 'No verified admin account is available for the test'; end if;
  perform set_config('request.jwt.claim.sub',admin_uid::text,true);
  select min(state_id) into sid from fauxlore.state_profiles;
  select official_race_id into official_race from fauxlore.state_profiles where state_id=sid;
  select p.id into province_key from fauxlore.provinces p join fauxlore.province_values s on s.province_id=p.id and s.layer='states' and s.category_id=sid
    where p.kind='land' order by p.id limit 1;
  select id into other_race from fauxlore.map_categories where layer='races' and id<>official_race order by id limit 1;
  if province_key is null or other_race is null then raise exception 'Status test fixture is incomplete'; end if;
  update fauxlore.province_values pv set category_id=other_race where pv.province_id=province_key and pv.layer='races';
  perform fauxlore.ensure_state_group_politics(sid);
  response:=public.fauxlore_api('admin/states/'||sid||'/politics','PATCH',
    jsonb_build_object('group_type','race','group_id',other_race,'status','Ассимиляция'),command_id);
  repeated:=public.fauxlore_api('admin/states/'||sid||'/politics','PATCH',
    jsonb_build_object('group_type','race','group_id',other_race,'status','Ассимиляция'),command_id);
  if response is distinct from repeated or (response->>'cost')::integer<>0 or response->>'status'<>'Ассимиляция' then
    raise exception 'Admin status change or idempotent retry failed';
  end if;
  politics:=public.fauxlore_api('admin/states/'||sid||'/politics','GET','{}',null);
  if not exists(select 1 from jsonb_array_elements(politics) as rows(value) where value->>'group_type'='race'
      and value->>'group_key'=other_race::text and value->>'status'='Ассимиляция' and (value->>'changed_this_turn')::boolean) then
    raise exception 'Politics read did not return the saved status and turn lock';
  end if;
  if fauxlore.group_status_loyalty_modifier(sid,'race',other_race)<>-.10
      or fauxlore.group_status_effect(sid,'race',other_race,'tax')<>.8
      or fauxlore.group_status_effect(sid,'race',other_race,'production')<>.7
      or fauxlore.group_status_effect(sid,'race',other_race,'population')<>.5
      or fauxlore.group_status_effect(sid,'race',other_race,'recruit')<>0 then
    raise exception 'Assimilation coefficients mismatch';
  end if;
  begin
    perform public.fauxlore_api('admin/states/'||sid||'/politics','PATCH',
      jsonb_build_object('group_type','race','group_id',official_race,'status','Истребление'),gen_random_uuid());
    raise exception 'Official group status was mutable';
  exception when sqlstate '22023' then null;
  end;
end $$;
select 'Race/religion status API, idempotency, turn lock, coefficients and official-group lock passed' result;
rollback;
