begin;
do $$
declare c record; s record; step jsonb; sid integer; metrics jsonb; result jsonb; prior jsonb; rid uuid; endpoint text; other_state integer;
begin
  for c in select * from (values(0,6),(39.99,6),(40,4),(59.99,4),(60,2),(79.99,2),(80,1),(94.99,1),(95,0),(100,0)) t(coverage,expected) loop
    for s in select * from (values(0,2),(.2499,2),(.25,1),(.4999,1),(.5,0),(.7499,0),(.75,-1),(1,-1)) t(stability,expected) loop
      step:=fauxlore.crime_step(c.coverage,s.stability);
      if (step->>'food_step_pp')::integer<>c.expected or (step->>'stability_step_pp')::integer<>s.expected
        or (step->>'crime_step_pp')::integer<>greatest(-1,least(6,c.expected+s.expected)) then raise exception 'Boundary mismatch'; end if;
    end loop;
  end loop;
  perform set_config('request.jwt.claim.sub',(select auth_user_id::text from fauxlore.accounts where role='admin' and auth_user_id is not null limit 1),true);
  select min(state_id) into sid from fauxlore.state_profiles;
  endpoint:='admin/states/'||sid||'/indicators';rid:=gen_random_uuid();
  perform set_config('fauxlore.test_indicator_state',sid::text,true);
  result:=public.fauxlore_api(endpoint,'PATCH','{"development_limit":0}',rid);
  if public.fauxlore_api(endpoint,'PATCH','{"development_limit":0}',rid)<>result then raise exception 'Limit retry mismatch'; end if;
  metrics:=public.fauxlore_api(endpoint,'GET','{}',null);
  if metrics->>'development_limit'<>'0' or metrics->>'overload_ratio' is not null then raise exception 'Zero limit mismatch'; end if;
  begin
    perform public.fauxlore_api(endpoint,'PATCH','{"development_limit":-1}',gen_random_uuid());
    raise exception 'Negative limit accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.fauxlore_api(endpoint,'PATCH','{"development_limit":1.5}',gen_random_uuid());
    raise exception 'Fractional limit accepted';
  exception when sqlstate '22023' then null;
  end;
  update fauxlore.provinces p set development=null from fauxlore.province_values v
    where p.id=v.province_id and v.layer='states' and v.category_id=sid and p.kind='land';
  metrics:=fauxlore.state_indicators(sid);
  if metrics->>'total_development' is not null or (metrics->>'missing_development_count')::integer=0 then raise exception 'Missing development lost'; end if;
  select min(state_id) into other_state from fauxlore.state_profiles where state_id<>sid;
  -- Five provinces: capital, city, region, empty territory, occupied region.
  with fixture as (select p.id,row_number() over(order by p.id) n from fauxlore.provinces p
    join fauxlore.province_values v on v.province_id=p.id and v.layer='states' and v.category_id=sid where p.kind='land')
  update fauxlore.provinces p set population=(array[10000,3000,2500,0,500])[f.n],
    development=(array[100,null,0,50,200])[f.n],
    province_type=(array['Столичная','Городская','Регион','Территориальная','Регион'])[f.n],
    occupation=case when f.n=5 then (select name from fauxlore.map_categories where layer='states' and id=other_state) else null end
    from fixture f where p.id=f.id;
  metrics:=fauxlore.state_indicators(sid);
  if (metrics->>'population')::numeric<>16000 or (metrics->>'urban_population')::numeric<>4100
    or (metrics->>'rural_population')::numeric<>11900 or (metrics->>'total_development')::numeric<>350
    or metrics->>'missing_development_count'<>'1' then raise exception 'Mixed province fixture mismatch'; end if;
  update fauxlore.province_values rv set category_id=(select id from fauxlore.map_categories where layer='races' and name='Люди')
    where rv.layer='races' and exists(select 1 from fauxlore.province_values ov where ov.province_id=rv.province_id and ov.layer='states' and ov.category_id=sid);
  metrics:=fauxlore.state_indicators(sid);
  if (metrics->>'urbanization_growth_multiplier')::numeric<>.946875 or (metrics->>'population_growth')::numeric<>225 then raise exception 'Urbanization growth mismatch'; end if;
  update fauxlore.provinces p set population=0 from fauxlore.province_values v
    where p.id=v.province_id and v.layer='states' and v.category_id=sid and p.kind='land';
  metrics:=fauxlore.state_indicators(sid);
  if metrics->>'urbanization'<>'0' then raise exception 'Zero population urbanization mismatch'; end if;
  delete from fauxlore.province_values where layer='states' and category_id=sid;
  metrics:=fauxlore.state_indicators(sid);
  if metrics->>'province_count'<>'0' or metrics->>'total_development'<>'0' then raise exception 'Empty state mismatch'; end if;
  if has_function_privilege('anon','fauxlore.state_indicators(integer)','execute')
    or has_function_privilege('anon','fauxlore.state_indicators_api(text,text,jsonb,uuid)','execute') then raise exception 'Private helper exposed'; end if;
end $$;
set local role authenticated;
select public.fauxlore_api('admin/states/'||current_setting('fauxlore.test_indicator_state')||'/indicators','GET','{}',null)->>'development_limit' as authenticated_dispatch;
reset role;
select '80 threshold combinations, limit validation/retry, missing development and private helpers passed' result;
rollback;
