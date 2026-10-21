-- All test users and gameplay changes are rolled back. No sign-in tokens are
-- issued; only transaction-local JWT claims are simulated by the database owner.
begin;
set local statement_timeout='8s';
set local role anon;
do $$ begin
  if (public.fauxlore_api('health')->>'database')<>'supabase' then raise exception 'health'; end if;
  if jsonb_array_length(public.fauxlore_api('map')->'provinces')<1000 then raise exception 'map'; end if;
  if public.fauxlore_api('auth/me')<>'{"user":null}' then raise exception 'guest'; end if;
  begin
    perform public.fauxlore_api('admin/provinces/1','PATCH','{"population":3}',gen_random_uuid());
    raise exception 'Guest mutation permitted';
  exception when invalid_authorization_specification then null; end;
  begin perform public.fauxlore_api('admin/roads','POST','{}',gen_random_uuid());raise exception 'Guest road write';
  exception when invalid_authorization_specification then null; end;
  begin
    perform public.fauxlore_api('admin/categories/resources/2','PATCH','{"color":"#112233"}',gen_random_uuid());
    raise exception 'Guest color mutation permitted';
  exception when invalid_authorization_specification then null; end;
  begin perform 1 from fauxlore.accounts; raise exception 'Account disclosure';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Simulate the existing administrator completing Google OAuth for the first time.
-- A disposable legacy account keeps this test repeatable after real users sign in.
insert into fauxlore.accounts(id,email,nickname,role,google_sub)
  values(900000000001,'fauxlore-admin-test@gmail.com','Администратор теста','admin','fauxlore-test-admin');
insert into auth.users(id,email,email_confirmed_at,raw_app_meta_data)
  select 'a7f00a00-0000-4000-8000-000000000001',email,now(),'{"provider":"google","providers":["google"]}'
  from fauxlore.accounts where id=900000000001;
insert into auth.identities(provider_id,user_id,provider,identity_data)
  select coalesce(google_sub,'fauxlore-test-admin'),'a7f00a00-0000-4000-8000-000000000001','google',
    jsonb_build_object('sub',coalesce(google_sub,'fauxlore-test-admin'),'email',email,'email_verified',true,'name',nickname)
  from fauxlore.accounts where id=900000000001;
select set_config('request.jwt.claims','{"sub":"a7f00a00-0000-4000-8000-000000000001","role":"authenticated"}',true);
set local role authenticated;
do $$ declare p jsonb; pid integer; result jsonb; repeated jsonb; request uuid:=gen_random_uuid(); marker jsonb; map_row jsonb;
begin
  if public.fauxlore_api('auth/me')->'user'->>'role'<>'admin' then raise exception 'Legacy administrator lost'; end if;
  marker:=public.fauxlore_api('admin/categories/resources/2','PATCH','{"color":"#123ABC"}',request);
  if marker->>'color'<>'#123abc' then raise exception 'Color update'; end if;
  if marker<>public.fauxlore_api('admin/categories/resources/2','PATCH','{"color":"#123ABC"}',request) then raise exception 'Color idempotency'; end if;
  request:=gen_random_uuid();
  if not exists(select 1 from jsonb_array_elements(public.fauxlore_api('map')->'categories') c where c->>'layer'='resources' and c->>'id'='2' and c->>'color'='#123abc') then raise exception 'Map color not updated'; end if;
  begin
    perform public.fauxlore_api('admin/categories/resources/2','PATCH','{"color":"red"}',gen_random_uuid());
    raise exception 'Invalid color accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.fauxlore_api('admin/categories/resources/2','PATCH','{"color":"#112233","name":"Renamed"}',gen_random_uuid());
    raise exception 'Unexpected category field accepted';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.fauxlore_api('admin/categories/resources/999999','PATCH','{"color":"#112233"}',gen_random_uuid());
    raise exception 'Missing category accepted';
  exception when no_data_found then null; end;
  select value into p from jsonb_array_elements(public.fauxlore_api('map')->'provinces') where value->>'kind'='land' limit 1;
  pid:=(p->>'id')::integer;
  result:=public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"population":2345,"belonging":"Корона","trade_status":"Устье реки","terrain_type":"forest"}',request);
  if (result->>'population')::int<>2345 or result->>'belonging'<>'Корона' or result->>'trade_status'<>'Устье реки' or result->>'terrain_type'<>'forest' then raise exception 'Province edit'; end if;
  repeated:=public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"population":2345,"belonging":"Корона","trade_status":"Устье реки","terrain_type":"forest"}',request);
  if result<>repeated then raise exception 'Idempotency'; end if;
  result:=public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"state":"Тестовая страна переноса","race":"Люди","control":50}',gen_random_uuid());
  if (result->>'control')::int<>50 then raise exception 'Numeric province control'; end if;
  result:=public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"occupation":"Тестовая страна переноса"}',gen_random_uuid());
  if result->>'occupation'<>'Тестовая страна переноса' or result->>'occupation_color' is null then raise exception 'Province occupation'; end if;
  select value into map_row from jsonb_array_elements(public.fauxlore_api('map')->'provinces') where (value->>'id')::integer=pid;
  if map_row->>'occupation'<>'Тестовая страна переноса' or map_row->>'occupation_color' is null then raise exception 'Occupation map payload'; end if;
  result:=public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"occupation":null}',gen_random_uuid());
  if result->>'occupation' is not null or result->>'occupation_color' is not null then raise exception 'Clear occupation'; end if;
  begin perform public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"control":101}',gen_random_uuid()); raise exception 'Invalid control accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"population":2500}',request); raise exception 'Request id reused';
  exception when invalid_parameter_value then null; end;
  begin perform public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"population":-1}',gen_random_uuid()); raise exception 'Invalid number accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"belonging":"Короли"}',gen_random_uuid()); raise exception 'Invalid belonging accepted';
  exception when invalid_parameter_value then null; end;
  begin perform public.fauxlore_api('admin/provinces/'||pid,'PATCH','{"trade_status":"Региональный рынок"}',gen_random_uuid()); raise exception 'Invalid trade status accepted';
  exception when invalid_parameter_value then null; end;
  result:=public.fauxlore_api('preferences','PUT','{"layer":"races","role":"admin"}',gen_random_uuid());
  result:=public.fauxlore_api('preferences');
  if result<>'{"layer":"races"}' then raise exception 'Preferences'; end if;
  perform public.fauxlore_api('profile/avatar','POST','{"image_data":null}',gen_random_uuid());
  marker:=public.fauxlore_api('admin/markers','POST',jsonb_build_object('province_id',pid,'x',p->'center'->0,'y',p->'center'->1,'type','city','name','Тест переноса'),gen_random_uuid());
  perform public.fauxlore_api('admin/markers/'||(marker->>'id'),'DELETE','{}',gen_random_uuid());
  -- A short center-to-marker segment; all writes and its deletion roll back.
  marker:=public.fauxlore_api('admin/markers','POST',jsonb_build_object('province_id',pid,'x',p->'center'->0,'y',p->'center'->1,'type','city','name','Точка дороги'),gen_random_uuid());
  repeated:=jsonb_build_object('type','imperial','anchors',jsonb_build_array(
    jsonb_build_object('kind','province','province_id',pid,'x',p->'center'->0,'y',p->'center'->1),
    jsonb_build_object('kind','marker','marker_id',marker->'id','province_id',pid,'x',marker->'x','y',marker->'y')),
    'segments',jsonb_build_array(jsonb_build_array(p->'center',p->'center')));
  request:=gen_random_uuid();result:=public.fauxlore_api('admin/roads','POST',repeated,request);
  if result->>'type'<>'imperial' or jsonb_array_length(result->'anchors')<>2 then raise exception 'Road creation'; end if;
  if result<>public.fauxlore_api('admin/roads','POST',repeated,request) then raise exception 'Road idempotency'; end if;
  if not exists(select 1 from jsonb_array_elements(public.fauxlore_api('map')->'roads') road where road->>'id'=result->>'id') then raise exception 'Road map payload'; end if;
  perform public.fauxlore_api('admin/roads/'||(result->>'id'),'DELETE','{}',gen_random_uuid());
  begin perform public.fauxlore_api('admin/roads','POST',jsonb_set(repeated,'{type}','"invalid"'),gen_random_uuid());raise exception 'Invalid road type';
  exception when invalid_parameter_value then null; end;
  begin perform public.fauxlore_api('admin/roads','POST',jsonb_set(repeated,'{anchors,0,x}','0'),gen_random_uuid());raise exception 'Invalid anchor';
  exception when invalid_parameter_value then null; end;
  perform public.fauxlore_api('admin/markers/'||(marker->>'id'),'DELETE','{}',gen_random_uuid());
  result:=public.fauxlore_api('admin/provinces/bulk-preview','POST','{"rules":[{"condition_field":"population","condition_value":2345,"target_field":"development","target_value":17}]}',gen_random_uuid());
  if (result->>'total')::int<1 then raise exception 'Bulk preview'; end if;
  result:=public.fauxlore_api('admin/provinces/bulk-edit','POST','{"rules":[{"condition_field":"population","condition_value":2345,"target_field":"development","target_value":17}]}',gen_random_uuid());
  if (result->>'updated_count')::int<1 then raise exception 'Bulk edit'; end if;
  result:=public.fauxlore_api('admin/provinces/bulk-preview','POST','{"rules":[{"condition_field":"population","condition_value":2345,"target_field":"development","target_value":17},{"condition_field":"population","condition_value":2345,"target_field":"development","target_value":18}]}',gen_random_uuid());
  if (result->>'conflict_count')::int<1 then raise exception 'Bulk conflict detection'; end if;
  result:=public.fauxlore_api('admin/provinces/bulk-edit','POST','{"rules":[{"condition_field":"province_type","condition_value":"Нейтральная","target_field":"development","target_value":10}]}',gen_random_uuid());
  if (result->>'updated_count')::int<100 then raise exception 'Large bulk edit'; end if;
end $$;
reset role;
insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data,raw_app_meta_data)
  values('a7f00a00-0000-4000-8000-000000000002','fauxlore-migration-test@gmail.com',now(),'{"role":"admin"}','{"provider":"google","providers":["google"]}');
insert into auth.identities(provider_id,user_id,provider,identity_data)
  values('fauxlore-test-player','a7f00a00-0000-4000-8000-000000000002','google',
    '{"sub":"fauxlore-test-player","email":"fauxlore-migration-test@gmail.com","email_verified":true}');
select set_config('request.jwt.claims','{"sub":"a7f00a00-0000-4000-8000-000000000002","role":"authenticated","user_metadata":{"role":"admin"}}',true);
set local role authenticated;
do $$ begin
  if public.fauxlore_api('auth/me')->'user'->>'role'<>'player' then raise exception 'Metadata privilege escalation'; end if;
  begin perform public.fauxlore_api('admin/roads','POST','{}',gen_random_uuid());raise exception 'Player road write';
  exception when insufficient_privilege then null; end;
  begin perform public.fauxlore_api('admin/categories/resources/2','PATCH','{"color":"#112233"}',gen_random_uuid()); raise exception 'Player color mutation permitted';
  exception when insufficient_privilege then null; end;
  begin perform public.fauxlore_api('admin/provinces/1','PATCH','{"population":3}',gen_random_uuid()); raise exception 'Player mutation permitted';
  exception when insufficient_privilege then null; end;
end $$;
rollback;
select 'Guest access, private data, Google linking, role isolation, edits, bulk edits, markers, preferences and idempotency: passed (rolled back)' as result;
