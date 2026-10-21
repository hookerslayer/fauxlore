-- Persist computed turn reports and advance the calendar atomically.
alter table fauxlore.provinces drop column if exists warehouse;

create table if not exists fauxlore.game_calendar (
  singleton boolean primary key default true check (singleton),
  year integer not null check (year > 0),
  turn integer not null check (turn > 0),
  updated_at timestamptz not null default now()
);
insert into fauxlore.game_calendar(singleton,year,turn) values(true,1452,1)
on conflict(singleton) do nothing;
alter table fauxlore.game_calendar enable row level security;
revoke all on fauxlore.game_calendar from public,anon,authenticated;

create table if not exists fauxlore.turn_economy_reports (
  year integer not null,
  turn integer not null,
  report jsonb not null check(jsonb_typeof(report)='array'),
  created_by bigint not null references fauxlore.accounts(id),
  created_at timestamptz not null default now(),
  primary key(year,turn)
);
alter table fauxlore.turn_economy_reports enable row level security;
revoke all on fauxlore.turn_economy_reports from public,anon,authenticated;

create or replace function fauxlore.turn_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; calendar_row fauxlore.game_calendar; previous fauxlore.operations;
  fingerprint text; result jsonb; report_value jsonb;
begin
  if path='game/calendar' and method='GET' then
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    return jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn);
  end if;
  if path<>'admin/turn/advance' or method<>'POST' or
    body-array['expected_year','expected_turn','report']<>'{}' or
    jsonb_typeof(body->'report') is distinct from 'array' or
    octet_length(coalesce(body->'report','[]'::jsonb)::text)>1500000 then
    raise sqlstate '22023' using message='Некорректный запрос смены хода';
  end if;
  a:=fauxlore.current_account();
  if a.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if request_id is null then raise sqlstate '22023' using message='Нужен идентификатор команды'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=turn_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true for update;
  if calendar_row.year<>(body->>'expected_year')::integer or calendar_row.turn<>(body->>'expected_turn')::integer then
    raise sqlstate '40001' using message='Ход уже изменён в другой сессии. Обновите страницу и повторите.';
  end if;
  report_value:=body->'report';
  insert into fauxlore.turn_economy_reports(year,turn,report,created_by)
    values(calendar_row.year,calendar_row.turn,report_value,a.id);
  update fauxlore.game_calendar set year=year+1,turn=turn+1,updated_at=now()
    where singleton=true returning * into calendar_row;
  result:=jsonb_build_object('year',calendar_row.year,'turn',calendar_row.turn,
    'calculated_year',calendar_row.year-1,'calculated_turn',calendar_row.turn-1,
    'states_calculated',jsonb_array_length(report_value));
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(a.id,turn_api.request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.turn_api(text,text,jsonb,uuid) from public,anon,authenticated;
grant execute on function fauxlore.turn_api(text,text,jsonb,uuid) to anon,authenticated;

create or replace function public.fauxlore_api(path text,method text default 'GET',body jsonb default '{}',request_id uuid default null)
returns jsonb language sql security invoker set search_path='' as $$
  select case
    when path='admin/states' then fauxlore.state_api(path,method,body,request_id)
    when path='my/states' or path like 'admin/states/%' then fauxlore.game_state_api(path,method,body,request_id)
    when path='game/calendar' or path='admin/turn/advance' then fauxlore.turn_api(path,method,body,request_id)
    else fauxlore.api(path,method,body,request_id)
  end
$$;
revoke all on function public.fauxlore_api(text,text,jsonb,uuid) from public;
grant execute on function public.fauxlore_api(text,text,jsonb,uuid) to anon,authenticated;
notify pgrst,'reload schema';
