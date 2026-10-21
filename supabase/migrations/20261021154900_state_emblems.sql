-- State emblems are stored alongside state profiles, matching the existing
-- profile-avatar data URI flow. The API exposes public reads and admin writes.
alter table fauxlore.state_profiles
  add column if not exists emblem_base64 text,
  add column if not exists emblem_type text;

create or replace function fauxlore.state_emblem_api(path text, method text, body jsonb, request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  a fauxlore.accounts;
  state_value integer;
  state_name text;
  image_data text;
  image_type text;
  image_bytes bytea;
  result jsonb;
  previous fauxlore.operations;
  fingerprint text;
begin
  if jsonb_typeof(body) is distinct from 'object' then
    raise sqlstate '22023' using message='Некорректный запрос';
  end if;

  if method='GET' and path ~ '^state-emblem/[0-9]+$' then
    state_value:=split_part(path,'/',2)::integer;
    select c.name into state_name from fauxlore.map_categories c
      where c.layer='states' and c.id=state_value;
    if not found then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
    select jsonb_build_object('emblem_url',case when sp.emblem_base64 is null then null
      else 'data:'||sp.emblem_type||';base64,'||sp.emblem_base64 end)
      into result from fauxlore.state_profiles sp where sp.state_id=state_value;
    return coalesce(result,jsonb_build_object('emblem_url',null));
  end if;

  if method<>'POST' or path !~ '^admin/state-emblem/[0-9]+$' or not (body ? 'image_data') or
     body-array['image_data']<>'{}'::jsonb then
    raise sqlstate '22023' using message='Некорректный запрос символики';
  end if;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;

  state_value:=split_part(path,'/',3)::integer;
  select c.name into state_name from fauxlore.map_categories c
    where c.layer='states' and c.id=state_value for update;
  if not found then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  image_data:=body->>'image_data';
  image_type:=null;
  if image_data is not null then
    if image_data !~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=\r\n]+$' then
      raise sqlstate '22023' using message='Допустимы только JPG, JPEG, PNG или WebP';
    end if;
    image_type:=split_part(substr(image_data,6),';',1);
    begin
      image_bytes:=decode(split_part(image_data,',',2),'base64');
    exception when others then
      raise sqlstate '22023' using message='Не удалось прочитать файл символики';
    end;
    if octet_length(image_bytes)>2097152 then
      raise sqlstate '22023' using message='Изображение символики должно быть не больше 2 МБ';
    end if;
  end if;

  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o
    where o.account_id=a.id and o.request_id=state_emblem_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then
      raise sqlstate '22023' using message='Идентификатор команды уже использован';
    end if;
    return previous.result;
  end if;

  update fauxlore.state_profiles set emblem_base64=case when image_data is null then null else split_part(image_data,',',2) end,
    emblem_type=image_type where state_id=state_value;
  if not found then raise sqlstate 'P0002' using message='Профиль государства не найден'; end if;
  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  result:=jsonb_build_object('ok',true,'has_emblem',image_data is not null,'state_id',state_value);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(a.id,state_emblem_api.request_id,fingerprint,result);
  return result;
end $$;

revoke all on function fauxlore.state_emblem_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.state_emblem_api(text,text,jsonb,uuid) to anon,authenticated;

create or replace function public.fauxlore_api(path text, method text default 'GET', body jsonb default '{}', request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$'
      then fauxlore.state_emblem_api(path,method,body,request_id)
    when path='game/calendar' or path='admin/turn/advance'
      then fauxlore.turn_api(path,method,body,request_id)
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    when path='my/states' or path like 'admin/states/%'
      then fauxlore.game_state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id)
  end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst, 'reload schema';
