-- Trade phase 1: server-validated, auditable trade-agreement lifecycle.
-- Settlement and market clearing are intentionally added in later phases.

create table if not exists fauxlore.trade_agreements (
  id bigint generated always as identity primary key,
  from_state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  to_state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  from_city_province_id integer not null references fauxlore.provinces(id),
  to_city_province_id integer not null references fauxlore.provinces(id),
  route_province_ids integer[] not null check(array_length(route_province_ids,1) between 2 and 10),
  terms jsonb not null check(jsonb_typeof(terms)='object'),
  status text not null default 'pending' check(status in ('pending','accepted','declined','cancelled')),
  proposal_cost smallint not null default 3 check(proposal_cost in (0,3)),
  created_by bigint not null references fauxlore.accounts(id),
  answered_by bigint references fauxlore.accounts(id),
  created_year integer not null,
  created_turn integer not null,
  accepted_year integer,
  accepted_turn integer,
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  check(from_state_id<>to_state_id),
  check(route_province_ids[1]=from_city_province_id),
  check(route_province_ids[array_length(route_province_ids,1)]=to_city_province_id)
);
create index if not exists trade_agreements_from_state_idx on fauxlore.trade_agreements(from_state_id,status,created_at desc);
create index if not exists trade_agreements_to_state_idx on fauxlore.trade_agreements(to_state_id,status,created_at desc);
alter table fauxlore.trade_agreements enable row level security;
revoke all on fauxlore.trade_agreements from public,anon,authenticated;

create or replace function fauxlore.trade_resource_surplus(state_value integer,resource_value text)
returns numeric language sql stable security definer set search_path='' as $$
  with cfg as (select config from fauxlore.economy_parameters where singleton=true),
  resource_config as (select r from cfg cross join lateral jsonb_array_elements(cfg.config->'resources') r where r->>'name'=resource_value limit 1),
  owned_population as (
    select coalesce(sum(p.population),0)::numeric amount from fauxlore.provinces p
    join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states' and owner.category_id=state_value
    where p.kind='land'
  ),
  output as (
    select coalesce(sum(round(greatest(p.population,0)::numeric*(rc.r->>'production')::numeric*
      (cfg.config#>>array['provinceModifiers',p.province_type,'production'])::numeric*
      coalesce(p.control,100)::numeric/100*(1-coalesce(owner_profile.crime,.2))*
      case when p.occupation is not null and lower(p.occupation)<>lower(owner.name)
        then coalesce((cfg.config->>'occupationMultiplier')::numeric,.5) else 1 end,0)),0)::numeric amount
    from fauxlore.provinces p
    join fauxlore.province_values rv on rv.province_id=p.id and rv.layer='resources'
    join fauxlore.map_categories resource on resource.layer='resources' and resource.id=rv.category_id and resource.name=resource_value
    left join fauxlore.province_values owner_value on owner_value.province_id=p.id and owner_value.layer='states'
    left join fauxlore.map_categories owner on owner.layer='states' and owner.id=owner_value.category_id
    left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
    left join fauxlore.state_profiles owner_profile on owner_profile.state_id=owner.id
    cross join cfg cross join resource_config rc
    where p.kind='land' and (case when p.occupation is not null and lower(p.occupation)<>lower(coalesce(owner.name,'')) then occupier.id else owner.id end)=state_value
  )
  select coalesce(output.amount,0)-ceil(owned_population.amount/10*(resource_config.r->>'consumption')::numeric)
  from output cross join owned_population cross join resource_config
$$;
revoke all on function fauxlore.trade_resource_surplus(integer,text) from public,anon,authenticated;

create or replace function fauxlore.trade_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor fauxlore.accounts; calendar_row fauxlore.game_calendar; previous fauxlore.operations;
  state_from integer; state_to integer; origin_id integer; destination_id integer;
  route_ids integer[]; route_len integer; segment integer; terms_value jsonb; goods_value jsonb;
  from_goods jsonb; to_goods jsonb; from_gold numeric; to_gold numeric; amount_value numeric;
  item jsonb; resource_name text; config_value jsonb; state_row record; agreement_row fauxlore.trade_agreements;
  action text; agreement_id bigint; fingerprint text; result jsonb; cost_value smallint;
begin
  actor:=fauxlore.current_account();
  if path='my/trade-agreements' and method='GET' and body='{}'::jsonb then
    return jsonb_build_object(
      'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name)
        from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id
        where c.layer='states' and (actor.role='admin' or exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.state_id=c.id and ast.layer='states'))),'[]'::jsonb),
      'targets',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name)
        from fauxlore.map_categories c join fauxlore.state_profiles sp on sp.state_id=c.id where c.layer='states'),'[]'::jsonb),
      'cities',coalesce((select jsonb_agg(jsonb_build_object('province_id',p.id,'state_id',v.category_id,'name',p.name,
          'kind',case when p.has_capital_marker then 'Столица' else 'Город' end) order by p.name,p.id)
        from fauxlore.provinces p join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
        where p.kind='land' and (p.has_capital_marker or p.has_city_marker)),'[]'::jsonb),
      'resources',coalesce((select jsonb_agg(jsonb_build_object('name',r->>'name','category',r->>'category') order by r->>'category',r->>'name')
        from fauxlore.economy_parameters ep cross join lateral jsonb_array_elements(ep.config->'resources') r
        where ep.singleton and coalesce((r->>'showInProduction')::boolean,true)),'[]'::jsonb),
      'agreements',coalesce((select jsonb_agg(jsonb_build_object('id',ta.id,'from_state_id',ta.from_state_id,'from_state',fs.name,
          'to_state_id',ta.to_state_id,'to_state',ts.name,'from_city_province_id',ta.from_city_province_id,
          'to_city_province_id',ta.to_city_province_id,'route_province_ids',ta.route_province_ids,'terms',ta.terms,'status',ta.status,
          'proposal_cost',ta.proposal_cost,'created_year',ta.created_year,'created_turn',ta.created_turn,
          'accepted_year',ta.accepted_year,'accepted_turn',ta.accepted_turn,'created_at',ta.created_at,
          'incoming',(actor.role='admin' or exists(select 1 from fauxlore.account_states own where own.account_id=actor.id and own.layer='states' and own.state_id=ta.to_state_id)))
          order by ta.created_at desc)
        from fauxlore.trade_agreements ta join fauxlore.map_categories fs on fs.layer='states' and fs.id=ta.from_state_id
        join fauxlore.map_categories ts on ts.layer='states' and ts.id=ta.to_state_id
        where actor.role='admin' or exists(select 1 from fauxlore.account_states own where own.account_id=actor.id and own.layer='states' and own.state_id in(ta.from_state_id,ta.to_state_id))),'[]'::jsonb)
    );
  end if;

  if path='my/trade-agreements' and method='POST' then
    if request_id is null or jsonb_typeof(body) is distinct from 'object' or
      body-'from_state_id'-'to_state_id'-'from_city_province_id'-'to_city_province_id'-'route_province_ids'-'from_goods'-'to_goods'-'from_gold'-'to_gold'<>'{}'::jsonb or
      coalesce(body->>'from_state_id','')!~'^\d+$' or coalesce(body->>'to_state_id','')!~'^\d+$' or
      coalesce(body->>'from_city_province_id','')!~'^\d+$' or coalesce(body->>'to_city_province_id','')!~'^\d+$' or
      jsonb_typeof(body->'route_province_ids') is distinct from 'array' or
      jsonb_typeof(coalesce(body->'from_goods','[]'::jsonb)) is distinct from 'array' or
      jsonb_typeof(coalesce(body->'to_goods','[]'::jsonb)) is distinct from 'array' then
      raise sqlstate '22023' using message='Заполните государства, города, маршрут и условия предложения';
    end if;
    state_from:=(body->>'from_state_id')::integer; state_to:=(body->>'to_state_id')::integer;
    origin_id:=(body->>'from_city_province_id')::integer; destination_id:=(body->>'to_city_province_id')::integer;
    if state_from=state_to then raise sqlstate '22023' using message='Выберите разные государства'; end if;
    if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id=state_from) then
      raise sqlstate '42501' using message='Нет доступа к отправляющему государству'; end if;
    if exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id=state_to) then
      raise sqlstate '22023' using message='Нельзя отправить предложение самому себе'; end if;
    if not exists(select 1 from fauxlore.state_profiles where state_id=state_to) then raise sqlstate 'P0002' using message='Государство-получатель не найдено'; end if;
    if jsonb_array_length(body->'route_province_ids') not between 2 and 10 or exists(
      select 1 from jsonb_array_elements_text(body->'route_province_ids') r(value) where value!~'^\d+$') then
      raise sqlstate '22023' using message='Маршрут должен содержать от 2 до 10 ID провинций по порядку'; end if;
    select array_agg(value::integer) into route_ids from jsonb_array_elements_text(body->'route_province_ids') r(value);
    route_len:=array_length(route_ids,1);
    if route_ids[1]<>origin_id or route_ids[route_len]<>destination_id or
      (select count(distinct x) from unnest(route_ids) x)<>route_len then
      raise sqlstate '22023' using message='Маршрут должен начинаться и заканчиваться выбранными городами и не содержать повторов'; end if;
    if not exists(select 1 from fauxlore.provinces p join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
      where p.id=origin_id and p.kind='land' and (p.has_capital_marker or p.has_city_marker) and v.category_id=state_from) or
      not exists(select 1 from fauxlore.provinces p join fauxlore.province_values v on v.province_id=p.id and v.layer='states'
      where p.id=destination_id and p.kind='land' and (p.has_capital_marker or p.has_city_marker) and v.category_id=state_to) then
      raise sqlstate '22023' using message='Начальная и конечная провинции должны быть городами выбранных государств'; end if;
    if exists(select 1 from unnest(route_ids) x left join fauxlore.provinces p on p.id=x where p.id is null or p.kind not in('land','sea')) then
      raise sqlstate '22023' using message='В маршруте найдена неизвестная или непроходимая провинция'; end if;
    select neighbors into config_value from fauxlore.map_adjacency where singleton;
    for segment in 1..route_len-1 loop
      if not exists(select 1 from jsonb_array_elements_text(config_value->route_ids[segment]::text) n(value) where value=(route_ids[segment+1])::text) then
        raise sqlstate '22023' using message='Соседние провинции маршрута не соединены: '||route_ids[segment]||' → '||route_ids[segment+1]; end if;
      if exists(select 1 from fauxlore.provinces a join fauxlore.provinces b on b.id=route_ids[segment+1]
        where a.id=route_ids[segment] and (a.kind='sea')<>(b.kind='sea') and not exists(
          select 1 from fauxlore.map_markers m where m.province_id=case when a.kind='sea' then a.id else b.id end and m.type='port')) then
        raise sqlstate '22023' using message='Для перехода между сушей и морем нужен порт в морской провинции'; end if;
    end loop;
    from_goods:=coalesce(body->'from_goods','[]'::jsonb); to_goods:=coalesce(body->'to_goods','[]'::jsonb);
    if jsonb_array_length(from_goods)>20 or jsonb_array_length(to_goods)>20 then raise sqlstate '22023' using message='В одну сторону можно включить не более 20 ресурсов'; end if;
    select config into config_value from fauxlore.economy_parameters where singleton=true;
    foreach goods_value in array array[from_goods,to_goods] loop
      if exists(select 1 from jsonb_array_elements(goods_value) e(value) where jsonb_typeof(value) is distinct from 'object'
        or value-'name'-'quantity'<>'{}'::jsonb or jsonb_typeof(value->'name') is distinct from 'string'
        or coalesce(value->>'name','')='' or coalesce(value->>'quantity','')!~'^\d+(\.\d{1,2})?$'
        or (value->>'quantity')::numeric<=0 or (value->>'quantity')::numeric>1000000000
        or not exists(select 1 from jsonb_array_elements(config_value->'resources') r where r->>'name'=value->>'name' and coalesce((r->>'showInProduction')::boolean,true))) then
        raise sqlstate '22023' using message='Проверьте названия и положительные количества ресурсов'; end if;
      if exists(select lower(value->>'name') from jsonb_array_elements(goods_value) e(value) group by lower(value->>'name') having count(*)>1) then
        raise sqlstate '22023' using message='Один ресурс нельзя указать в одной стороне предложения дважды'; end if;
    end loop;
    for item in select value from jsonb_array_elements(from_goods) e(value) loop
      if (item->>'quantity')::numeric>fauxlore.trade_resource_surplus(state_from,item->>'name') then
        raise sqlstate '22023' using message='Предложено больше текущего излишка ресурса «'||(item->>'name')||'»'; end if;
    end loop;
    for item in select value from jsonb_array_elements(to_goods) e(value) loop
      if (item->>'quantity')::numeric>fauxlore.trade_resource_surplus(state_to,item->>'name') then
        raise sqlstate '22023' using message='Государство-получатель сейчас не имеет такого излишка ресурса «'||(item->>'name')||'»'; end if;
    end loop;
    if coalesce(body->>'from_gold','0')!~'^\d+(\.\d{1,2})?$' or coalesce(body->>'to_gold','0')!~'^\d+(\.\d{1,2})?$' then
      raise sqlstate '22023' using message='Денежные суммы должны быть неотрицательными G с точностью до 2 знаков'; end if;
    from_gold:=coalesce((body->>'from_gold')::numeric,0); to_gold:=coalesce((body->>'to_gold')::numeric,0);
    if from_gold>100000000000 or to_gold>100000000000 or (jsonb_array_length(from_goods)=0 and jsonb_array_length(to_goods)=0 and from_gold=0 and to_gold=0) then
      raise sqlstate '22023' using message='Укажите хотя бы один ресурс или денежный перевод'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);
    perform pg_advisory_xact_lock(hashtextextended(actor.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=actor.id and o.request_id=trade_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    cost_value:=case when actor.role='admin' then 0 else 3 end;
    select * into state_row from fauxlore.state_profiles where state_id=state_from for update;
    if cost_value>0 then
      if coalesce(state_row.prestige,0)<cost_value then raise sqlstate '22023' using message='Для предложения требуется 3 ОП'; end if;
      update fauxlore.state_profiles set prestige=prestige-cost_value where state_id=state_from;
    end if;
    terms_value:=jsonb_build_object('from_goods',from_goods,'to_goods',to_goods,'from_gold',from_gold,'to_gold',to_gold);
    insert into fauxlore.trade_agreements(from_state_id,to_state_id,from_city_province_id,to_city_province_id,route_province_ids,
      terms,proposal_cost,created_by,created_year,created_turn)
    values(state_from,state_to,origin_id,destination_id,route_ids,terms_value,cost_value,actor.id,calendar_row.year,calendar_row.turn)
    returning * into agreement_row;
    result:=jsonb_build_object('id',agreement_row.id,'status',agreement_row.status,'proposal_cost',cost_value,'created_year',calendar_row.year,'created_turn',calendar_row.turn);
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(actor.id,request_id,fingerprint,result);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'trade_offer','Предложен торговый договор',
        (select name from fauxlore.map_categories where layer='states' and id=state_from)||' предлагает торговый договор государству «'||
        (select name from fauxlore.map_categories where layer='states' and id=state_to)||'». Предложение ожидает ответа.'
      from fauxlore.account_states ast where ast.layer='states' and ast.state_id=state_to
      union select ac.id,'trade_offer','Предложен торговый договор',
        (select name from fauxlore.map_categories where layer='states' and id=state_from)||' предлагает торговый договор государству «'||
        (select name from fauxlore.map_categories where layer='states' and id=state_to)||'». Предложение ожидает ответа.'
      from fauxlore.accounts ac where ac.role='admin' and not exists(select 1 from fauxlore.account_states ast where ast.layer='states' and ast.state_id=state_to);
    return result;
  end if;

  if path ~ '^(my|admin)/trade-agreements/[0-9]+/(accept|decline|cancel)$' and method='POST' then
    if body<>'{}'::jsonb or request_id is null then raise sqlstate '22023' using message='Некорректная команда по торговому договору'; end if;
    action:=split_part(path,'/',4); agreement_id:=split_part(path,'/',3)::bigint;
    if split_part(path,'/',1)='admin' and actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    fingerprint:=md5(jsonb_build_array(method,path,body)::text);
    perform pg_advisory_xact_lock(hashtextextended(actor.id::text||':'||request_id::text,0));
    select * into previous from fauxlore.operations o where o.account_id=actor.id and o.request_id=trade_api.request_id;
    if found then if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return previous.result; end if;
    select * into agreement_row from fauxlore.trade_agreements where id=agreement_id for update;
    if not found then raise sqlstate 'P0002' using message='Торговый договор не найден'; end if;
    if action='accept' or action='decline' then
      if agreement_row.status<>'pending' then raise sqlstate '22023' using message='Предложение уже обработано'; end if;
      if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id=agreement_row.to_state_id) then
        raise sqlstate '42501' using message='Ответить на предложение может только государство-получатель'; end if;
      if action='accept' then select * into calendar_row from fauxlore.game_calendar where singleton=true;
        update fauxlore.trade_agreements set status='accepted',answered_by=actor.id,answered_at=now(),accepted_year=calendar_row.year,accepted_turn=calendar_row.turn where id=agreement_id;
      else update fauxlore.trade_agreements set status='declined',answered_by=actor.id,answered_at=now() where id=agreement_id; end if;
    else
      if agreement_row.status not in('pending','accepted') then raise sqlstate '22023' using message='Этот договор уже завершён'; end if;
      if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states ast where ast.account_id=actor.id and ast.layer='states' and ast.state_id in(agreement_row.from_state_id,agreement_row.to_state_id)) then
        raise sqlstate '42501' using message='Нет доступа к этому торговому договору'; end if;
      update fauxlore.trade_agreements set status='cancelled',answered_by=actor.id,answered_at=now() where id=agreement_id;
    end if;
    result:=jsonb_build_object('id',agreement_id,'status',case when action='accept' then 'accepted' when action='decline' then 'declined' else 'cancelled' end);
    insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(actor.id,request_id,fingerprint,result);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'trade_offer',case action when 'accept' then 'Торговый договор принят' when 'decline' then 'Торговый договор отклонён' else 'Торговый договор расторгнут' end,
        case action when 'accept' then 'Ваше предложение о торговле принято. Исполнение ресурсов и платежей будет включено следующим этапом.'
          when 'decline' then 'Ваше предложение о торговле отклонено.' else 'Торговый договор расторгнут.' end
      from fauxlore.account_states ast where ast.layer='states' and ast.state_id=case when actor.role='admin' then agreement_row.from_state_id else
        case when action='cancel' then case when exists(select 1 from fauxlore.account_states own where own.account_id=actor.id and own.state_id=agreement_row.from_state_id and own.layer='states') then agreement_row.to_state_id else agreement_row.from_state_id end else agreement_row.from_state_id end end;
    return result;
  end if;
  raise sqlstate 'P0002' using message='Метод API торговли не найден';
end $$;
revoke all on function fauxlore.trade_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.trade_api(text,text,jsonb,uuid) to anon,authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if path in ('my/economy/treasuries','admin/economy/treasuries') or path ~ '^(my|admin)/states/[0-9]+/tax-rates$' then return fauxlore.state_tax_rates_api(path,method,body,request_id);
  elsif path='admin/turn/test' or path like 'admin/turn/test/%' then return fauxlore.test_turn_api(path,method,body,request_id);
  elsif path='map/revision' and method='GET' then return fauxlore.map_revision();
  elsif path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then return fauxlore.character_lifecycle_api(path,method,body,request_id);
  elsif path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$' then return fauxlore.characters_api(path,method,body,request_id);
  elsif path='my/marriage-offers' or path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then return fauxlore.dynastic_marriage_api(path,method,body,request_id);
  elsif path='my/trade-agreements' or path ~ '^(my|admin)/trade-agreements/[0-9]+/(accept|decline|cancel)$' then return fauxlore.trade_api(path,method,body,request_id);
  elsif path ~ '^(my|admin)/states/[0-9]+/abdicate$' then return fauxlore.abdicate_api(path,method,body,request_id);
  elsif path ~ '^(my|admin)/states/[0-9]+/(succession(/events/[0-9]+/choose)?|politics|designate)$' then return fauxlore.succession_api(path,method,body,request_id);
  elsif path='my/applications' and method='GET' then return fauxlore.my_applications();
  elsif path='my/applications' and method='POST' then return fauxlore.registration_api_with_surname(path,method,body,request_id);
  elsif path ~ '^admin/applications/[0-9]+$' and method='PATCH' then return fauxlore.registration_api_with_surname(path,method,body,request_id);
  elsif path='my/applications' or path like 'admin/applications%' or path='notifications' or path like 'notifications/%' then return fauxlore.registration_api(path,method,body,request_id);
  elsif path ~ '^my/applications/[0-9]+$' then return fauxlore.application_details(path,method,body);
  elsif path ~ '^state-emblem/[0-9]+$' or path ~ '^admin/state-emblem/[0-9]+$' then return fauxlore.state_emblem_api(path,method,body,request_id);
  elsif path ~ '^admin/states/[0-9]+/army$' then return fauxlore.army_budget_api(path,method,body,request_id);
  elsif path='admin/turn/latest-report' then return fauxlore.turn_budget_report_api(path,method);
  elsif path='game/calendar' or path='admin/turn/advance' then return fauxlore.turn_api(path,method,body,request_id);
  elsif path='admin/states' then return fauxlore.state_api(path,method,body,request_id);
  elsif path='my/states' or path like 'admin/states/%' then return fauxlore.game_state_api(path,method,body,request_id);
  else return fauxlore.api(path,method,body,request_id); end if;
end $$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
