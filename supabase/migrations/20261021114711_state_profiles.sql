create table if not exists fauxlore.state_profiles (
  state_layer text not null default 'states' check (state_layer = 'states'),
  state_id integer primary key,
  is_npc boolean not null default true,
  principles jsonb not null,
  government_name text not null,
  race_layer text not null default 'races' check (race_layer = 'races'),
  official_race_id integer not null,
  religion_layer text not null default 'religions' check (religion_layer = 'religions'),
  official_religion_id integer not null,
  corruption numeric(5,4) not null default 0.2 check (corruption between 0.02 and 0.9),
  created_by bigint references fauxlore.accounts(id),
  created_at timestamptz not null default now(),
  foreign key (state_layer,state_id) references fauxlore.map_categories(layer,id),
  foreign key (race_layer,official_race_id) references fauxlore.map_categories(layer,id),
  foreign key (religion_layer,official_religion_id) references fauxlore.map_categories(layer,id)
);
alter table fauxlore.state_profiles enable row level security;
revoke all on fauxlore.state_profiles from public,anon,authenticated;

create or replace function fauxlore.government_form(chosen jsonb) returns text
language plpgsql immutable set search_path='' as $$
declare authority text:=chosen->>'authority'; structure text:=chosen->>'structure';
  economy text:=chosen->>'economy'; military text:=chosen->>'military';
  bases text[]; base text; economic text; army text; style integer; gender text;
begin
  if authority is null or authority<>all(array['Династия','Магистрат','Клир','Диктат','Вече']) or
     structure is null or structure<>all(array['Ленное право','Деспотизм','Консорциум','Содружество','Командорство']) or
     economy is null or economy<>all(array['Крепостничество','Гильдии','Адмиралтейство','Корсарство','Работорговля']) or
     military is null or military<>all(array['Сословная армия','Кондотьеры','Фирд','Гвардия','Тумены']) then
    raise sqlstate '22023' using message='Неизвестный принцип государства';
  end if;
  if (military='Тумены' and (economy=any(array['Гильдии','Адмиралтейство','Корсарство']) or structure=any(array['Консорциум','Командорство']))) or
     (military='Фирд' and authority=any(array['Династия','Диктат'])) or
     (authority='Клир' and economy='Корсарство') or
     (authority='Вече' and structure='Деспотизм' and economy='Крепостничество') then
    raise sqlstate '22023' using message='Выбранные принципы несовместимы';
  end if;
  bases:=case authority
    when 'Династия' then array['Феодальная монархия','Деспотия','Патримониалия','Уния','Марка']
    when 'Магистрат' then array['Республика','Олигархия','Директория','Вольный союз','Подеста']
    when 'Клир' then array['Княжество-епископство','Теократия','Аббатская синьория','Конгрегация','Орден']
    when 'Диктат' then array['Синьория','Тирания','Компания','Протекторат','Стратократия']
    else array['Боярская республика','Революционная диктатура','Коммуна','Кантональный союз','Вольница'] end;
  base:=bases[array_position(array['Ленное право','Деспотизм','Консорциум','Содружество','Командорство'],structure)];
  style:=case when authority=any(array['Магистрат','Вече']) then 1 else 2 end;
  economic:=(case economy
    when 'Крепостничество' then array['Аграрная','Поместная']
    when 'Гильдии' then array['Торговая','Ганзейская']
    when 'Адмиралтейство' then array['Морская','Флотская']
    when 'Корсарство' then array['Пиратская','Каперская']
    else array['Работорговая','Рабовладельческая'] end)[style];
  army:=(case military
    when 'Сословная армия' then array['Шляхетская','Рыцарская']
    when 'Кондотьеры' then array['Вольная','Кондотьерская']
    when 'Фирд' then array['Гражданская','Земская']
    when 'Гвардия' then array['Патрицианская','Гвардейская']
    else array['Степная','Ордынская'] end)[style];
  gender:=case when base='Княжество-епископство' then 'n'
    when base=any(array['Вольный союз','Орден','Протекторат','Кантональный союз']) then 'm' else 'f' end;
  if gender='m' then
    army:=regexp_replace(regexp_replace(army,'ская$','ский'),'ая$','ый');
    economic:=regexp_replace(regexp_replace(economic,'ская$','ский'),'ая$','ый');
  elsif gender='n' then
    army:=regexp_replace(regexp_replace(army,'ская$','ское'),'ая$','ое');
    economic:=regexp_replace(regexp_replace(economic,'ская$','ское'),'ая$','ое');
  end if;
  return army||' '||economic||' '||base;
end $$;
revoke all on function fauxlore.government_form(jsonb) from public,anon,authenticated;

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
      'form_name',s.government_name,'principles',s.principles,
      'official_race',r.name,'official_religion',rel.name,
      'corruption',coalesce(s.corruption,0.2),
      'province_count',(select count(*) from fauxlore.province_values v where v.layer='states' and v.category_id=c.id),
      'population',(select coalesce(sum(p.population),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id),
      'taxes',(select coalesce(sum(p.taxes),0) from fauxlore.province_values v join fauxlore.provinces p on p.id=v.province_id where v.layer='states' and v.category_id=c.id),
      'players',coalesce((select jsonb_agg(ac.nickname order by ac.nickname) from fauxlore.account_states ast join fauxlore.accounts ac on ac.id=ast.account_id where ast.state_id=c.id),'[]'::jsonb)
    ) order by c.name),'[]'::jsonb) into result
    from fauxlore.map_categories c
    left join fauxlore.state_profiles s on s.state_id=c.id
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
  if body-array['name','color','authority','structure','economy','military','ephemeral','race_id','religion_id']<>'{}' then
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
  if body->>'ephemeral' is null or body->>'ephemeral'<>all(array['Мораторий','Придворные чародеи','Герметизм','Святые Таинства','Артефакторика']) then
    raise sqlstate '22023' using message='Неизвестный эфемерный принцип'; end if;
  chosen:=jsonb_build_object('authority',body->>'authority','structure',body->>'structure',
    'economy',body->>'economy','military',body->>'military','ephemeral',body->>'ephemeral');
  form_name:=fauxlore.government_form(chosen);
  perform pg_advisory_xact_lock(hashtextextended('fauxlore:state-category',0));
  select coalesce(max(id),0)+1 into state_id from fauxlore.map_categories where layer='states';
  insert into fauxlore.map_categories(layer,id,name,color) values('states',state_id,state_name,lower(state_color));
  insert into fauxlore.state_profiles(state_id,principles,government_name,official_race_id,official_religion_id,created_by)
    values(state_id,chosen,form_name,race_id,religion_id,a.id);
  update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
  result:=jsonb_build_object('id',state_id,'name',state_name,'color',lower(state_color),'is_npc',true,
    'form_name',form_name,'principles',chosen,'corruption',0.2,'province_count',0,'population',0,'taxes',0,
    'official_race',(select name from fauxlore.map_categories where layer='races' and id=race_id),
    'official_religion',(select name from fauxlore.map_categories where layer='religions' and id=religion_id),'players','[]'::jsonb);
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,state_api.request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.state_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.state_api(text,text,jsonb,uuid) to authenticated;

create or replace function public.fauxlore_api(path text, method text default 'GET', body jsonb default '{}', request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id) end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst, 'reload schema';
