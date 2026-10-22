-- Player-adjustable race/religion tax rates, an administrator treasury view,
-- and a guarded test-turn checkpoint that can be rolled back safely.

create table if not exists fauxlore.state_tax_rates (
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  layer text not null check(layer in ('races','religions')),
  category_id integer not null,
  rate numeric(8,4) not null check(rate>=0 and rate<=100),
  changed_year integer not null,
  changed_turn integer not null,
  changed_by bigint not null references fauxlore.accounts(id),
  updated_at timestamptz not null default now(),
  primary key(state_id,layer,category_id),
  foreign key(layer,category_id) references fauxlore.map_categories(layer,id)
);
alter table fauxlore.state_tax_rates enable row level security;
revoke all on fauxlore.state_tax_rates from public,anon,authenticated;
create index if not exists state_tax_rates_layer_category_idx on fauxlore.state_tax_rates(layer,category_id);
drop trigger if exists fauxlore_live_revision on fauxlore.state_tax_rates;
create trigger fauxlore_live_revision after insert or update or delete on fauxlore.state_tax_rates
for each statement execute function fauxlore.bump_live_revision();

create table if not exists fauxlore.turn_test_snapshot (
  singleton boolean primary key default true check(singleton),
  payload jsonb not null,
  before_year integer not null,
  before_turn integer not null,
  after_year integer,
  after_turn integer,
  after_revision bigint,
  actor_id bigint not null references fauxlore.accounts(id),
  advance_request_id uuid not null,
  created_at timestamptz not null default now()
);
alter table fauxlore.turn_test_snapshot enable row level security;
revoke all on fauxlore.turn_test_snapshot from public,anon,authenticated;

create or replace function fauxlore.effective_state_tax_rate(state_key integer,layer_key text,category_key integer,fallback_config jsonb)
returns numeric language sql stable security definer set search_path='' as $$
  select coalesce(
    (select r.rate from fauxlore.state_tax_rates r where r.state_id=state_key and r.layer=layer_key and r.category_id=category_key),
    nullif(fallback_config#>>array[case layer_key when 'races' then 'raceTaxRates' else 'religionTaxRates' end,
      (select c.name from fauxlore.map_categories c where c.layer=layer_key and c.id=category_key)],'')::numeric
  )
$$;
revoke all on function fauxlore.effective_state_tax_rate(integer,text,integer,jsonb) from public,anon,authenticated;

-- Patch the installed Stage 4 function without copying its long annual lifecycle logic.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.turn_api(text,text,jsonb,uuid)'::regprocedure),chr(13),'');
  if position('fauxlore.effective_state_tax_rate' in fn)>0 then return; end if;
  fn:=replace(fn,'beneficiary_id integer; beneficiary_name text; tax_share numeric; expected_year integer; expected_turn integer;',
    'beneficiary_id integer; beneficiary_name text; tax_share numeric; expected_year integer; expected_turn integer; race_rate numeric; religion_rate numeric;');
  fn:=replace(fn,'race.name race_name,religion.name religion_name,owner.id owner_id,owner.name owner_name,',
    'race.name race_name,rv.category_id race_id,religion.name religion_name,relv.category_id religion_id,owner.id owner_id,owner.name owner_name,');
  old_fragment:='if nullif(cfg#>>array[''provinceModifiers'',province_row.province_type,''tax''],'''') is null or'||chr(10)||
       '       nullif(cfg#>>array[''raceTaxRates'',province_row.race_name],'''') is null or'||chr(10)||
       '       nullif(cfg#>>array[''religionTaxRates'',province_row.religion_name],'''') is null then'||chr(10)||
       '      raise sqlstate ''22023'' using message=''Не заданы налоговые коэффициенты провинции ''||province_row.id; end if;';
  new_fragment:='race_rate:=fauxlore.effective_state_tax_rate(beneficiary_id,''races'',province_row.race_id,cfg);'||chr(10)||
       '    religion_rate:=fauxlore.effective_state_tax_rate(beneficiary_id,''religions'',province_row.religion_id,cfg);'||chr(10)||
       '    if nullif(cfg#>>array[''provinceModifiers'',province_row.province_type,''tax''],'''') is null or race_rate is null or religion_rate is null then'||chr(10)||
       '      raise sqlstate ''22023'' using message=''Не заданы налоговые коэффициенты провинции ''||province_row.id; end if;';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate the Stage 4 tax validation fragment'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='((cfg#>>array[''raceTaxRates'',province_row.race_name])::numeric+(cfg#>>array[''religionTaxRates'',province_row.religion_name])::numeric) *';
  if position(old_fragment in fn)=0 then raise exception 'Could not locate the Stage 4 tax calculation fragment'; end if;
  fn:=replace(fn,old_fragment,'(race_rate+religion_rate) *');
  execute fn;
end $$;

create or replace function fauxlore.state_tax_rates_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; state_key integer; state_name text; calendar_row fauxlore.game_calendar; cfg jsonb;
  layer_key text; category_key integer; rate_value numeric; category_name text; prior fauxlore.operations;
  fp text; result jsonb; existing fauxlore.state_tax_rates; is_admin boolean;
begin
  a:=fauxlore.current_account(); is_admin:=a.role='admin';
  if path='admin/economy/treasuries' and method='GET' then
    if not is_admin then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id',s.state_id,'name',c.name,'treasury',s.treasury,'prestige',s.prestige,
      'debt',coalesce(d.balance,0),'players',coalesce((select jsonb_agg(ac.nickname order by ac.nickname) from fauxlore.account_states ast join fauxlore.accounts ac on ac.id=ast.account_id where ast.layer='states' and ast.state_id=s.state_id and ac.role<>'admin'),'[]'::jsonb),
      'buckets',coalesce((select jsonb_object_agg(t.estate,t.balance order by t.estate) from fauxlore.state_treasuries t where t.state_id=s.state_id),'{}'::jsonb)) order by c.name)
      from fauxlore.state_profiles s join fauxlore.map_categories c on c.layer='states' and c.id=s.state_id
      left join fauxlore.state_treasury_debts d on d.state_id=s.state_id),'[]'::jsonb);
  end if;
  if path !~ '^(my|admin)/states/[0-9]+/tax-rates$' then raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  if (path like 'admin/%') is distinct from is_admin then raise sqlstate '42501' using message='Недостаточно прав'; end if;
  state_key:=substring(path from '[0-9]+')::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=state_key) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if not is_admin and not exists(select 1 from fauxlore.account_states ast where ast.account_id=a.id and ast.layer='states' and ast.state_id=state_key) then
    raise sqlstate '42501' using message='Это государство не закреплено за вашим аккаунтом'; end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true;
  select config into cfg from fauxlore.economy_parameters where singleton=true;
  select c.name into state_name from fauxlore.map_categories c where c.layer='states' and c.id=state_key;
  if method='GET' then
    return jsonb_build_object('state_id',state_key,'state_name',state_name,'year',calendar_row.year,'turn',calendar_row.turn,
      'prestige',(select prestige from fauxlore.state_profiles where state_id=state_key),
      'treasury',(select treasury from fauxlore.state_profiles where state_id=state_key),
      'debt',coalesce((select balance from fauxlore.state_treasury_debts where state_id=state_key),0),
      'buckets',coalesce((select jsonb_object_agg(estate,balance) from fauxlore.state_treasuries where state_id=state_key),'{}'::jsonb),
      'groups',coalesce((select jsonb_agg(jsonb_build_object('layer',l.layer,'id',c.id,'name',c.name,
        'base_rate',(cfg#>>array[case l.layer when 'races' then 'raceTaxRates' else 'religionTaxRates' end,c.name])::numeric,
        'rate',coalesce(r.rate,(cfg#>>array[case l.layer when 'races' then 'raceTaxRates' else 'religionTaxRates' end,c.name])::numeric),
        'changed_this_turn',coalesce(r.changed_year=calendar_row.year and r.changed_turn=calendar_row.turn,false)) order by l.layer,c.name)
        from (values('races'::text),('religions'::text)) l(layer) join fauxlore.map_categories c on c.layer=l.layer
        left join fauxlore.state_tax_rates r on r.state_id=state_key and r.layer=l.layer and r.category_id=c.id),'[]'::jsonb));
  end if;
  if method not in ('POST','PATCH') or request_id is null or jsonb_typeof(body) is distinct from 'object' or body-array['layer','category_id','rate']<>'{}' or
    jsonb_typeof(body->'layer') is distinct from 'string' or jsonb_typeof(body->'category_id') is distinct from 'number' or jsonb_typeof(body->'rate') is distinct from 'number' then
    raise sqlstate '22023' using message='Некорректное изменение базовой ставки'; end if;
  layer_key:=body->>'layer'; category_key:=(body->>'category_id')::integer; rate_value:=(body->>'rate')::numeric;
  if layer_key not in ('races','religions') or rate_value<0 or rate_value>100 then raise sqlstate '22023' using message='Ставка должна быть от 0 до 100 G'; end if;
  select name into category_name from fauxlore.map_categories where layer=layer_key and id=category_key;
  if category_name is null or not ((cfg->(case layer_key when 'races' then 'raceTaxRates' else 'religionTaxRates' end)) ? category_name) then
    raise sqlstate '22023' using message='Для выбранной группы не задана базовая ставка'; end if;
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into prior from fauxlore.operations o where o.account_id=a.id and o.request_id=state_tax_rates_api.request_id;
  fp:=md5(jsonb_build_array(method,path,body)::text);
  if found then if prior.fingerprint<>fp then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if; return prior.result; end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true for share;
  select * into existing from fauxlore.state_tax_rates where state_id=state_key and layer=layer_key and category_id=category_key for update;
  if found and existing.changed_year=calendar_row.year and existing.changed_turn=calendar_row.turn then
    raise sqlstate '22023' using message='Эту ставку уже меняли в текущем ходу'; end if;
  if not is_admin then
    update fauxlore.state_profiles set prestige=prestige-3 where state_id=state_key and prestige>=3;
    if not found then raise sqlstate '22023' using message='Недостаточно ОП: изменение ставки стоит 3 ОП'; end if;
  end if;
  insert into fauxlore.state_tax_rates(state_id,layer,category_id,rate,changed_year,changed_turn,changed_by)
    values(state_key,layer_key,category_key,rate_value,calendar_row.year,calendar_row.turn,a.id)
    on conflict(state_id,layer,category_id) do update set rate=excluded.rate,changed_year=excluded.changed_year,changed_turn=excluded.changed_turn,changed_by=excluded.changed_by,updated_at=now();
  result:=jsonb_build_object('state_id',state_key,'state_name',state_name,'layer',layer_key,'category_id',category_key,'category_name',category_name,
    'rate',rate_value,'cost',case when is_admin then 0 else 3 end,'prestige',(select prestige from fauxlore.state_profiles where state_id=state_key));
  insert into fauxlore.operations(account_id,request_id,fingerprint,result) values(a.id,state_tax_rates_api.request_id,fp,result);
  return result;
end $$;
revoke all on function fauxlore.state_tax_rates_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.state_tax_rates_api(text,text,jsonb,uuid) to authenticated;

create or replace function fauxlore.test_turn_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; cal fauxlore.game_calendar; snap fauxlore.turn_test_snapshot; payload jsonb; result jsonb; revision bigint; t text; snap_row jsonb;
begin
  a:=fauxlore.current_account(); if a.role is distinct from 'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if path='admin/turn/test' and method='GET' then
    select * into snap from fauxlore.turn_test_snapshot where singleton=true;
    if not found then return jsonb_build_object('active',false); end if;
    return jsonb_build_object('active',snap.after_revision is not null,'before_year',snap.before_year,'before_turn',snap.before_turn,
      'after_year',snap.after_year,'after_turn',snap.after_turn,'created_at',snap.created_at);
  end if;
  if path='admin/turn/test/advance' and method='POST' then
    if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
    if exists(select 1 from fauxlore.turn_test_snapshot where singleton=true) then raise sqlstate '22023' using message='Сначала откатите или завершите предыдущий тестовый ход'; end if;
    select * into cal from fauxlore.game_calendar where singleton=true for update;
    if (body->>'expected_year')::integer<>cal.year or (body->>'expected_turn')::integer<>cal.turn then raise sqlstate '40001' using message='Ход уже изменён. Обновите страницу.'; end if;
    select coalesce((value_json#>>'{}')::bigint,0) into revision from fauxlore._settings where key='live_revision';
    select jsonb_build_object(
      'state_profiles',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_profiles x),
      'state_group_politics',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_group_politics x),
      'state_characters',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_characters x),
      'state_succession_events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_succession_events x),
      'state_birth_events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_birth_events x),
      'notifications',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.notifications x),
      'state_treasuries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_treasuries x),
      'state_treasury_debts',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_treasury_debts x),
      'state_budget_ledger',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.state_budget_ledger x),
      'turn_economy_reports',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.turn_economy_reports x),
      'game_calendar',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from fauxlore.game_calendar x)
    ) into payload;
    insert into fauxlore.turn_test_snapshot(singleton,payload,before_year,before_turn,actor_id,advance_request_id)
      values(true,payload,cal.year,cal.turn,a.id,request_id);
    result:=fauxlore.turn_api('admin/turn/advance','POST',body,request_id);
    select * into cal from fauxlore.game_calendar where singleton=true;
    select coalesce((value_json#>>'{}')::bigint,0) into revision from fauxlore._settings where key='live_revision';
    update fauxlore.turn_test_snapshot set after_year=cal.year,after_turn=cal.turn,after_revision=revision where singleton=true;
    return result||jsonb_build_object('test_mode',true,'rollback_available',true);
  end if;
  if path='admin/turn/test/rollback' and method='POST' then
    select * into snap from fauxlore.turn_test_snapshot where singleton=true for update;
    if not found or snap.after_revision is null then raise sqlstate '22023' using message='Нет завершённого тестового хода для отката'; end if;
    lock table fauxlore.state_profiles,fauxlore.state_group_politics,fauxlore.state_characters,fauxlore.state_succession_events,
      fauxlore.state_birth_events,fauxlore.notifications,fauxlore.state_treasuries,fauxlore.state_treasury_debts,
      fauxlore.state_budget_ledger,fauxlore.turn_economy_reports,fauxlore.game_calendar in access exclusive mode;
    if (select coalesce((value_json#>>'{}')::bigint,0) from fauxlore._settings where key='live_revision')<>snap.after_revision then
      raise sqlstate '40001' using message='После тестового хода появились новые изменения. Откат отменён, чтобы их не затереть.'; end if;
    if not exists(select 1 from fauxlore.game_calendar where singleton and year=snap.after_year and turn=snap.after_turn) then
      raise sqlstate '40001' using message='Игровой календарь изменён после теста. Откат отменён.'; end if;
    perform set_config('session_replication_role','replica',true);
    delete from fauxlore.notifications; delete from fauxlore.state_birth_events; delete from fauxlore.state_budget_ledger;
    delete from fauxlore.turn_economy_reports; delete from fauxlore.state_succession_events; delete from fauxlore.state_group_politics;
    delete from fauxlore.state_characters; delete from fauxlore.state_treasuries; delete from fauxlore.state_treasury_debts;
    for t in select unnest(array['state_profiles','state_group_politics','state_characters','state_succession_events','state_birth_events','notifications','state_treasuries','state_treasury_debts','state_budget_ledger','turn_economy_reports','game_calendar']) loop
      snap_row:=snap.payload->t;
      if t='state_profiles' or t='game_calendar' then
        execute format('update fauxlore.%1$I target set %2$s from jsonb_populate_recordset(null::fauxlore.%1$I,$1) saved where target.%3$I=saved.%3$I',
          t,(select string_agg(format('%1$I=saved.%1$I',column_name),',' order by ordinal_position) from information_schema.columns where table_schema='fauxlore' and table_name=t and column_name<>case t when 'state_profiles' then 'state_id' else 'singleton' end),
          case t when 'state_profiles' then 'state_id' else 'singleton' end) using snap_row;
      else
        execute format('insert into fauxlore.%I select * from jsonb_populate_recordset(null::fauxlore.%I,$1)',t,t) using snap_row;
      end if;
    end loop;
    delete from fauxlore.operations where account_id=snap.actor_id and request_id=snap.advance_request_id;
    perform set_config('session_replication_role','origin',true);
    update fauxlore._settings set value_json=to_jsonb(coalesce((value_json#>>'{}')::bigint,0)+1) where key='live_revision';
    delete from fauxlore.turn_test_snapshot where singleton=true;
    return jsonb_build_object('rolled_back',true,'year',snap.before_year,'turn',snap.before_turn);
  end if;
  raise sqlstate 'P0002' using message='Метод API не найден';
end $$;
revoke all on function fauxlore.test_turn_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.test_turn_api(text,text,jsonb,uuid) to authenticated;

-- Include state-specific rates in the public map payload so province calculations use the active state's values.
do $$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.map_payload()'::regprocedure),chr(13),'');
  old_fragment:='case when v.layer=''states'' then jsonb_build_object(''crime'',coalesce((select sp.crime from fauxlore.state_profiles sp where sp.state_id=c.id),0.2)) else ''{}''::jsonb end';
  new_fragment:='case when v.layer=''states'' then jsonb_build_object(''crime'',coalesce((select sp.crime from fauxlore.state_profiles sp where sp.state_id=c.id),0.2),''race_tax_rates'',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer=''races''),''{}''::jsonb),''religion_tax_rates'',coalesce((select jsonb_object_agg(mc.name,r.rate) from fauxlore.state_tax_rates r join fauxlore.map_categories mc on mc.layer=r.layer and mc.id=r.category_id where r.state_id=c.id and r.layer=''religions''),''{}''::jsonb)) else ''{}''::jsonb end';
  if position('race_tax_rates' in fn)>0 then return; end if;
  if position(old_fragment in fn)=0 then raise exception 'Could not locate state layer JSON in map_payload'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $$;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
  if path in ('my/economy/treasuries','admin/economy/treasuries') or path ~ '^(my|admin)/states/[0-9]+/tax-rates$' then
    return fauxlore.state_tax_rates_api(path,method,body,request_id);
  elsif path='admin/turn/test' or path like 'admin/turn/test/%' then
    return fauxlore.test_turn_api(path,method,body,request_id);
  elsif path='map/revision' and method='GET' then return fauxlore.map_revision();
  elsif path ~ '^my/states/[0-9]+/(birth-events|birth-events/[0-9]+/name|marriage-candidates|marriages/local)$' then return fauxlore.character_lifecycle_api(path,method,body,request_id);
  elsif path ~ '^my/states/[0-9]+/characters$' or path ~ '^admin/states/[0-9]+/characters$' then return fauxlore.characters_api(path,method,body,request_id);
  elsif path='my/marriage-offers' or path ~ '^(my|admin)/marriage-offers/[0-9]+/(accept|reject)$' then return fauxlore.dynastic_marriage_api(path,method,body,request_id);
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
