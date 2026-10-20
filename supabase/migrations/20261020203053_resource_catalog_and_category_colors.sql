-- Keep resource IDs and province assignments intact.
update fauxlore.map_categories c set name=renames.new_name
from (values
 ('Древесина','Лес'),('Скот','Животноводство'),('Лён','Хлопок'),
 ('Железо','Металлы'),('Пушнина','Мех'),
 ('Самоцветы','Драгоценные металлы'),('Чаролист','Эфемера')
) as renames(old_name,new_name)
where c.layer='resources' and c.name=renames.old_name;

do $$ declare resource record; begin
 perform pg_advisory_xact_lock(hashtextextended('category:resources',0));
 for resource in select * from (values
  ('Красители','#d94aa6'),('Табак','#9a7b3f'),('Селитра','#ffb52e'),
  ('Сахар','#b0ff00'),('Чай','#28df36'),('Кофе','#6f4e37'),('Шёлк','#ffffff')
 ) as additions(name,color) loop
  if not exists(select 1 from fauxlore.map_categories where layer='resources' and lower(name)=lower(resource.name)) then
   insert into fauxlore.map_categories(layer,id,name,color)
    select 'resources',coalesce(max(id),0)+1,resource.name,resource.color
    from fauxlore.map_categories where layer='resources';
  end if;
 end loop;
end $$;

update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';

create or replace function fauxlore.api(path text, method text, body jsonb, request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; p fauxlore.provinces; m fauxlore.map_markers; result jsonb;
  previous fauxlore.operations; fingerprint text; id_value integer; marker_id bigint; state_value integer;
  avatar text; mime_value text; changes jsonb;
begin
  if length(path)>150 or method not in ('GET','POST','PATCH','PUT','DELETE') or
    jsonb_typeof(body) is distinct from 'object' or octet_length(body::text)>2900000 then
    raise sqlstate '22023' using message='Некорректный запрос'; end if;
  if path='health' and method='GET' then return jsonb_build_object('ok',true,'database','supabase'); end if;
  if path='map' and method='GET' then
    if not exists(select 1 from fauxlore._settings where key='migration_ready' and value_json='true') then
      raise sqlstate '55000' using message='Перенос данных ещё не завершён'; end if;
    return fauxlore.map_payload();
  end if;
  if path='auth/me' and method='GET' and auth.uid() is null then return '{"user":null}'; end if;
  a:=fauxlore.current_account();
  if path like 'admin/%' and a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if path='auth/me' and method='GET' then return jsonb_build_object('user',fauxlore.profile(a)); end if;
  if path='profile' and method='GET' then return fauxlore.profile(a); end if;
  if path='preferences' and method='GET' then return coalesce((select settings from fauxlore.user_preferences where account_id=a.id),'{}'); end if;
  if method='GET' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where account_id=a.id and o.request_id=api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  if path='preferences' and method='PUT' then
    select coalesce(jsonb_object_agg(key,value),'{}') into changes from jsonb_each(body) where key=any(array['layer','markers','information','showIds']);
    if octet_length(changes::text)>8192 then raise sqlstate '22023' using message='Слишком большой набор настроек'; end if;
    insert into fauxlore.user_preferences values(a.id,changes) on conflict(account_id) do update set settings=excluded.settings;
    result:='{"ok":true}';
  elsif path='profile/avatar' and method='POST' then
    avatar:=body->>'image_data';
    if avatar is not null then
      if avatar!~'^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\r\n]+$' then raise sqlstate '22023' using message='Неподдерживаемое изображение'; end if;
      mime_value:=split_part(substr(avatar,6),';',1);avatar:=split_part(avatar,',',2);
      if octet_length(decode(avatar,'base64'))>2097152 then raise sqlstate '22023' using message='Аватар должен быть не больше 2 МБ'; end if;
    end if;
    update fauxlore.accounts set avatar_base64=avatar,avatar_type=mime_value where id=a.id;
    result:='{"ok":true}';
  elsif path~'^admin/categories/(states|races|religions|resources|trade|climate)/[0-9]+$' and method='PATCH' then
    if body-'color'<>'{}' or jsonb_typeof(body->'color') is distinct from 'string' or
      (body->>'color')!~'^#[0-9a-fA-F]{6}$' then
      raise sqlstate '22023' using message='Укажите цвет в формате #RRGGBB'; end if;
    update fauxlore.map_categories set color=lower(body->>'color')
      where layer=split_part(path,'/',3) and id=split_part(path,'/',4)::integer
      returning to_jsonb(map_categories.*) into result;
    if not found then raise sqlstate 'P0002' using message='Значение параметра не найдено'; end if;
  elsif path in ('admin/provinces/bulk-preview','admin/provinces/bulk-edit') and method='POST' then
    result:=fauxlore.bulk_edit(body,path='admin/provinces/bulk-edit');
  elsif path~'^admin/provinces/\d+$' and method='PATCH' then
    result:=fauxlore.edit_province(split_part(path,'/',3)::integer,body);
  elsif path~'^provinces/\d+/name$' and method='PATCH' then
    id_value:=split_part(path,'/',2)::integer;
    if not exists(select 1 from fauxlore.province_values v join fauxlore.account_states s
      on s.state_id=v.category_id and s.account_id=a.id where v.province_id=id_value and v.layer='states') then
      raise sqlstate '42501' using message='Вы не владеете государством этой провинции'; end if;
    if body-'name'<>'{}' then raise sqlstate '22023' using message='Разрешено менять только название'; end if;
    result:=fauxlore.edit_province(id_value,body);result:=jsonb_build_object('id',id_value,'name',result->'name');
  elsif path='admin/markers' and method='POST' then
    if body-array['province_id','x','y','type','name','state_id']<>'{}' or body->>'type' not in ('capital','city','fortress','port') then
      raise sqlstate '22023' using message='Некорректный маркер'; end if;
    select * into p from fauxlore.provinces where id=(body->>'province_id')::integer;
    if not found then raise sqlstate 'P0002' using message='Провинция не найдена'; end if;
    if jsonb_typeof(body->'x') is distinct from 'number' or jsonb_typeof(body->'y') is distinct from 'number' or
      (body->>'x')::numeric<(p.bbox->>0)::numeric or (body->>'x')::numeric>=(p.bbox->>2)::numeric or
      (body->>'y')::numeric<(p.bbox->>1)::numeric or (body->>'y')::numeric>=(p.bbox->>3)::numeric then
      raise sqlstate '22023' using message='Точка не совпадает с выбранной провинцией'; end if;
    state_value:=(body->>'state_id')::integer;
    if state_value is null then select category_id into state_value from fauxlore.province_values where province_id=p.id and layer='states'; end if;
    insert into fauxlore.map_markers(province_id,x,y,type,name,state_id)
      values(p.id,(body->>'x')::float8,(body->>'y')::float8,body->>'type',fauxlore.normalize('name',body->'name')#>>'{}',state_value) returning * into m;
    result:=to_jsonb(m)||jsonb_build_object('state_name',(select name from fauxlore.map_categories where layer='states' and id=m.state_id));
  elsif path~'^admin/markers/\d+$' and method='DELETE' then
    marker_id:=split_part(path,'/',3)::bigint; delete from fauxlore.map_markers where id=marker_id;
    if not found then raise sqlstate 'P0002' using message='Маркер не найден'; end if;
    result:=jsonb_build_object('id',marker_id,'deleted',true);
  else raise sqlstate 'P0002' using message='Метод API не найден';
  end if;
  if path like 'admin/provinces/%' and path<>'admin/provinces/bulk-preview' or path like 'admin/markers%' or path like 'admin/categories/%' or path like 'provinces/%' then
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  end if;
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,api.request_id,fingerprint,result);
  return result;
end $$;
