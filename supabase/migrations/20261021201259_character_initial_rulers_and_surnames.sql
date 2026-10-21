alter table fauxlore.state_profiles add column if not exists ruler_surname text not null default '';
alter table fauxlore.state_applications add column if not exists ruler_surname text not null default '';
create index if not exists state_characters_father_idx on fauxlore.state_characters(father_id) where father_id is not null;
create index if not exists state_characters_mother_idx on fauxlore.state_characters(mother_id) where mother_id is not null;

create or replace function fauxlore.initialize_state_ruler()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if nullif(btrim(new.ruler_name),'') is not null and new.official_race_id is not null and new.official_religion_id is not null then
    insert into fauxlore.state_characters(state_id,name,surname,gender,title,age,race_id,religion_id,is_current_ruler)
    values(new.state_id,btrim(new.ruler_name),coalesce(nullif(new.ruler_surname,''),nullif(current_setting('fauxlore.ruler_surname',true),''),''),coalesce(new.ruler_gender,'Иной'),
      coalesce(new.ruler_title,''),greatest(0,least(250,coalesce(new.ruler_age,30))),new.official_race_id,new.official_religion_id,true)
    on conflict do nothing;
  end if;
  return new;
end $$;
revoke all on function fauxlore.initialize_state_ruler() from public,anon,authenticated;
drop trigger if exists state_profiles_initialize_ruler on fauxlore.state_profiles;
create trigger state_profiles_initialize_ruler after insert or update of ruler_name,ruler_surname,ruler_gender,ruler_title,ruler_age,official_race_id,official_religion_id
on fauxlore.state_profiles for each row execute function fauxlore.initialize_state_ruler();

create or replace function fauxlore.capture_application_surname()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  new.ruler_surname:=coalesce(nullif(btrim(current_setting('fauxlore.ruler_surname',true)),''),new.ruler_surname,'');
  return new;
end $$;
revoke all on function fauxlore.capture_application_surname() from public,anon,authenticated;
drop trigger if exists state_applications_capture_surname on fauxlore.state_applications;
create trigger state_applications_capture_surname before insert on fauxlore.state_applications
for each row execute function fauxlore.capture_application_surname();

create or replace function fauxlore.registration_api_with_surname(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; prior text; surname_value text;
begin
  prior:=current_setting('fauxlore.ruler_surname',true);
  if path='my/applications' and method='POST' then surname_value:=coalesce(body->>'ruler_surname','');
  elsif path ~ '^admin/applications/[0-9]+$' and method='PATCH' then
    select sa.ruler_surname into surname_value from fauxlore.state_applications sa where sa.id=split_part(path,'/',3)::bigint;
  else surname_value:=''; end if;
  perform set_config('fauxlore.ruler_surname',coalesce(surname_value,''),true);
  result:=fauxlore.registration_api(path,method,body-'ruler_surname',request_id);
  perform set_config('fauxlore.ruler_surname',coalesce(prior,''),true);
  return result;
exception when others then
  perform set_config('fauxlore.ruler_surname',coalesce(prior,''),true);
  raise;
end $$;
revoke all on function fauxlore.registration_api_with_surname(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.registration_api_with_surname(text,text,jsonb,uuid) to authenticated;

create or replace function fauxlore.state_api(path text, method text, body jsonb, request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; result jsonb; previous fauxlore.operations; fingerprint text;
  state_name text; state_color text; race_id integer; religion_id integer; state_id integer;
  chosen jsonb; form_name text;
begin
  if path<>'admin/states' or method not in ('GET','POST') or jsonb_typeof(body) is distinct from 'object' then
    raise sqlstate '22023' using message='Некорректный запрос'; end if;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if method='GET' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'name',c.name,'color',c.color,'is_npc',coalesce(s.is_npc,true),
      'form_name',s.government_name,'principles',s.principles,'official_race',r.name,'official_religion',rel.name,
      'corruption',coalesce(s.corruption,0.2),
      'province_count',(select count(*) from fauxlore.province_values v where v.layer='states' and v.category_id=c.id),
      'population',(select coalesce(sum(p.population),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id),
      'taxes',(select coalesce(sum(p.taxes),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id),
      'players',coalesce((select jsonb_agg(ac.nickname order by ac.nickname) from fauxlore.account_states ast join fauxlore.accounts ac on ac.id=ast.account_id where ast.state_id=c.id),'[]'::jsonb)
    ) order by c.name),'[]'::jsonb) into result
    from fauxlore.map_categories c left join fauxlore.state_profiles s on s.state_id=c.id
    left join fauxlore.map_categories r on r.layer='races' and r.id=s.official_race_id
    left join fauxlore.map_categories rel on rel.layer='religions' and rel.id=s.official_religion_id
    where c.layer='states';
    return result;
  end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=state_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  if body-array['name','color','authority','structure','economy','military','ephemeral','race_id','religion_id','ruler_name','ruler_surname','ruler_gender','ruler_title','ruler_age']<>'{}' then
    raise sqlstate '22023' using message='Неизвестное поле государства'; end if;
  state_name:=nullif(btrim(body->>'name'),''); state_color:=body->>'color';
  if state_name is null or length(state_name)>100 then raise sqlstate '22023' using message='Укажите название до 100 символов'; end if;
  if state_color is null or state_color!~'^#[0-9a-fA-F]{6}$' then raise sqlstate '22023' using message='Укажите цвет в формате #RRGGBB'; end if;
  if jsonb_typeof(body->'race_id') is distinct from 'number' or jsonb_typeof(body->'religion_id') is distinct from 'number' then
    raise sqlstate '22023' using message='Выберите расу и религию'; end if;
  race_id:=(body->>'race_id')::integer; religion_id:=(body->>'religion_id')::integer;
  if not exists(select 1 from fauxlore.map_categories where layer='races' and id=race_id) or
     not exists(select 1 from fauxlore.map_categories where layer='religions' and id=religion_id) then
    raise sqlstate '22023' using message='Раса или религия не найдена'; end if;
  if length(btrim(coalesce(body->>'ruler_name','')))<2 or length(btrim(coalesce(body->>'ruler_surname','')))<1 or
     body->>'ruler_gender' not in ('Мужской','Женский','Иной') or length(btrim(coalesce(body->>'ruler_title','')))<2 or
     coalesce((body->>'ruler_age')::integer,0) not between 16 and 250 then
    raise sqlstate '22023' using message='Заполните имя, фамилию, пол, титул и допустимый возраст правителя'; end if;
  if body->>'ephemeral' is null or body->>'ephemeral'<>all(array['Мораторий','Придворные чародеи','Герметизм','Святые Таинства','Артефакторика']) then
    raise sqlstate '22023' using message='Неизвестный эфемерный принцип'; end if;
  chosen:=jsonb_build_object('authority',body->>'authority','structure',body->>'structure','economy',body->>'economy','military',body->>'military','ephemeral',body->>'ephemeral');
  form_name:=fauxlore.government_form(chosen);
  perform pg_advisory_xact_lock(hashtextextended('fauxlore:state-category',0));
  select coalesce(max(id),0)+1 into state_id from fauxlore.map_categories where layer='states';
  insert into fauxlore.map_categories(layer,id,name,color) values('states',state_id,state_name,lower(state_color));
  insert into fauxlore.state_profiles(state_id,principles,government_name,official_race_id,official_religion_id,created_by,
    ruler_name,ruler_surname,ruler_gender,ruler_title,ruler_age)
    values(state_id,chosen,form_name,race_id,religion_id,a.id,btrim(body->>'ruler_name'),btrim(body->>'ruler_surname'),body->>'ruler_gender',btrim(body->>'ruler_title'),(body->>'ruler_age')::smallint);
  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  result:=jsonb_build_object('id',state_id,'name',state_name,'color',lower(state_color),'is_npc',true,'form_name',form_name,
    'principles',chosen,'corruption',0.2,'province_count',0,'population',0,'taxes',0,
    'official_race',(select name from fauxlore.map_categories where layer='races' and id=race_id),
    'official_religion',(select name from fauxlore.map_categories where layer='religions' and id=religion_id),
    'ruler_name',btrim(body->>'ruler_name'),'ruler_surname',btrim(body->>'ruler_surname'),'players','[]'::jsonb);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,state_api.request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.state_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.state_api(text,text,jsonb,uuid) to anon,authenticated;

create or replace function public.fauxlore_api(path text, method text default 'GET', body jsonb default '{}', request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$' then fauxlore.characters_api(path,method,body,request_id)
    when path='my/applications' and method='POST' then fauxlore.registration_api_with_surname(path,method,body,request_id)
    when path ~ '^admin/applications/[0-9]+$' and method='PATCH' then fauxlore.registration_api_with_surname(path,method,body,request_id)
    when path='my/applications' and method='GET' then fauxlore.my_applications()
    when path like 'my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%' then fauxlore.registration_api(path,method,body,request_id)
    when path ~ '^my/applications/[0-9]+$' then fauxlore.application_details(path,method,body)
    when path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then fauxlore.state_emblem_api(path,method,body,request_id)
    when path='game/calendar' or path='admin/turn/advance' then fauxlore.turn_api(path,method,body,request_id)
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id)
  end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
