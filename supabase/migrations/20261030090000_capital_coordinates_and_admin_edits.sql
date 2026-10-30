-- Keep the player's chosen capital point through review and state creation.
alter table fauxlore.state_applications
  add column if not exists capital_x double precision,
  add column if not exists capital_y double precision;

alter table fauxlore.state_applications
  add constraint state_applications_capital_point_pair
  check ((capital_x is null) = (capital_y is null));

do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');

  old_fragment:='''capital_province_id'',''capital_name'',''emblem_data''';
  new_fragment:='''capital_province_id'',''capital_x'',''capital_y'',''capital_name'',''emblem_data''';
  if position(old_fragment in fn)=0 then raise exception 'Registration field whitelist changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='    perform 1 from fauxlore.provinces where id=any(array(select v::integer from jsonb_array_elements_text(body->''province_ids'') e(v))) order by id for update;';
  new_fragment:=$new$    if jsonb_typeof(body->'capital_x') is distinct from 'number' or jsonb_typeof(body->'capital_y') is distinct from 'number' then
      raise sqlstate '22023' using message='Укажите точку столицы на карте'; end if;
    if fauxlore.military_province_mask_id((body->>'capital_x')::double precision,(body->>'capital_y')::double precision) is distinct from province_value then
      raise sqlstate '22023' using message='Точка столицы должна находиться внутри выбранной провинции'; end if;
$new$||old_fragment;
  if position(old_fragment in fn)=0 then raise exception 'Registration point validation insertion point changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='capital_province_id,capital_name,emblem_base64,emblem_type)';
  new_fragment:='capital_province_id,capital_x,capital_y,capital_name,emblem_base64,emblem_type)';
  if position(old_fragment in fn)=0 then raise exception 'Registration insert columns changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='province_value,'||chr(10)||'        btrim(body->>''capital_name'')';
  new_fragment:='province_value,(body->>''capital_x'')::double precision,(body->>''capital_y'')::double precision,'||chr(10)||'        btrim(body->>''capital_name'')';
  if position(old_fragment in fn)=0 then raise exception 'Registration insert values changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='values(app.capital_province_id,(province_item.center->>0)::float8,(province_item.center->>1)::float8,''capital'',app.capital_name,state_value);';
  new_fragment:='values(app.capital_province_id,coalesce(app.capital_x,(province_item.center->>0)::float8),coalesce(app.capital_y,(province_item.center->>1)::float8),''capital'',app.capital_name,state_value);';
  if position(old_fragment in fn)=0 then raise exception 'Capital marker creation changed'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='province_ids,capital_province_id,capital_name,emblem_type';
  new_fragment:='province_ids,capital_province_id,capital_x,capital_y,capital_name,emblem_type';
  if position(old_fragment in fn)=0 then raise exception 'Application summary changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.my_applications()'::regprocedure),chr(13),'');
  old_fragment:='sa.capital_province_id,sa.capital_name,sa.emblem_type';
  new_fragment:='sa.capital_province_id,sa.capital_x,sa.capital_y,sa.capital_name,sa.emblem_type';
  if position(old_fragment in fn)=0 then raise exception 'My applications summary changed'; end if;
  execute replace(fn,old_fragment,new_fragment);

  fn:=replace(pg_get_functiondef('fauxlore.application_details(text,text,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='''capital_province_id'',app.capital_province_id,''capital_name''';
  new_fragment:='''capital_province_id'',app.capital_province_id,''capital_x'',app.capital_x,''capital_y'',app.capital_y,''capital_name''';
  if position(old_fragment in fn)=0 then raise exception 'Application details changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;

-- A narrow server API for administrator corrections. The marker keeps its
-- province ID, so capital, port and garrison relationships remain intact.
create or replace function fauxlore.admin_marker_character_edit_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; marker_row fauxlore.map_markers; person fauxlore.state_characters;
  previous fauxlore.operations; fingerprint text; result jsonb; marker_key bigint; character_key bigint;
  name_value text; surname_value text; title_value text; x_value double precision; y_value double precision;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if method<>'PATCH' or jsonb_typeof(body) is distinct from 'object' or request_id is null then
    raise sqlstate '22023' using message='Некорректная команда редактирования'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(actor.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=actor.id and o.request_id=admin_marker_character_edit_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;

  if path ~ '^admin/markers/[0-9]+/position$' then
    if body-array['x','y']<>'{}'::jsonb or jsonb_typeof(body->'x') is distinct from 'number' or jsonb_typeof(body->'y') is distinct from 'number' then
      raise sqlstate '22023' using message='Укажите новые координаты маркера'; end if;
    marker_key:=split_part(path,'/',3)::bigint;
    select * into marker_row from fauxlore.map_markers where id=marker_key for update;
    if not found then raise sqlstate 'P0002' using message='Маркер не найден'; end if;
    x_value:=(body->>'x')::double precision;y_value:=(body->>'y')::double precision;
    if fauxlore.military_province_mask_id(x_value,y_value) is distinct from marker_row.province_id then
      raise sqlstate '22023' using message='Маркер можно перемещать только внутри его провинции'; end if;
    update fauxlore.map_markers set x=x_value,y=y_value where id=marker_key returning * into marker_row;
    result:=to_jsonb(marker_row)||jsonb_build_object('state_name',(select name from fauxlore.map_categories where layer='states' and id=marker_row.state_id));
  elsif path ~ '^admin/characters/[0-9]+$' then
    if body-array['name','surname','title']<>'{}'::jsonb or jsonb_typeof(body->'name') is distinct from 'string'
       or jsonb_typeof(body->'surname') is distinct from 'string' or jsonb_typeof(body->'title') is distinct from 'string' then
      raise sqlstate '22023' using message='Укажите имя, фамилию и титул персонажа'; end if;
    name_value:=btrim(body->>'name');surname_value:=btrim(body->>'surname');title_value:=btrim(body->>'title');
    if length(name_value) not between 1 and 100 or length(surname_value)>120 or length(title_value)>100 then
      raise sqlstate '22023' using message='Проверьте длину имени, фамилии и титула'; end if;
    character_key:=split_part(path,'/',3)::bigint;
    select * into person from fauxlore.state_characters where id=character_key for update;
    if not found then raise sqlstate 'P0002' using message='Персонаж не найден'; end if;
    update fauxlore.state_characters set name=name_value,surname=surname_value,title=title_value where id=character_key returning * into person;
    if person.is_current_ruler then
      update fauxlore.state_profiles set ruler_name=name_value,ruler_surname=surname_value,ruler_title=title_value where state_id=person.state_id;
    end if;
    result:=jsonb_build_object('id',person.id,'state_id',person.state_id,'name',person.name,'surname',person.surname,'title',person.title);
  else raise sqlstate 'P0002' using message='Команда редактирования не найдена'; end if;

  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(actor.id,admin_marker_character_edit_api.request_id,fingerprint,result);
  return result;
end
$function$;
revoke all on function fauxlore.admin_marker_character_edit_api(text,text,jsonb,uuid) from public,anon;
grant execute on function fauxlore.admin_marker_character_edit_api(text,text,jsonb,uuid) to authenticated;

do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=replace(pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  marker:='AS $function$ begin';
  replacement:=marker||chr(10)||
    ' if path ~ ''^admin/(markers/[0-9]+/position|characters/[0-9]+)$'' then return fauxlore.admin_marker_character_edit_api(path,method,body,request_id); end if;';
  if position(marker in fn)=0 then raise exception 'Public API route insertion point changed'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

select pg_notify('pgrst','reload schema');
