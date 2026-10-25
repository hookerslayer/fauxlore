-- Four-estate tax model. Activation of turn calculations is a later migration.
create table fauxlore.state_estate_tax_rates (
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  estate text not null check (estate in ('Знать','Духовенство','Горожане','Крестьяне')),
  rate numeric(10,2) not null check (rate between 0 and 10000),
  changed_year integer,
  changed_turn integer,
  changed_by bigint references fauxlore.accounts(id),
  updated_at timestamptz not null default now(),
  primary key(state_id,estate)
);
revoke all on fauxlore.state_estate_tax_rates from public,anon,authenticated;

update fauxlore.economy_parameters set config=config||jsonb_build_object('estateTaxRates',
  jsonb_build_object('Знать',10,'Духовенство',1,'Горожане',3,'Крестьяне',1))
where singleton=true;

create or replace function fauxlore.estate_population(province_kind text, inhabitants bigint)
returns table(estate text, population bigint)
language sql immutable security invoker set search_path='' as $$
with shares as (
  select case province_kind when 'Регион' then .01 when 'Городская' then .02 when 'Столичная' then .03 end noble,
         case province_kind when 'Регион' then .02 when 'Городская' then .03 when 'Столичная' then .04 end clergy,
         case province_kind when 'Регион' then .05 when 'Городская' then .30 when 'Столичная' then .38 end burgher
), counts as (
  select floor(greatest(inhabitants,0)::numeric*noble)::bigint noble,
    floor(greatest(inhabitants,0)::numeric*clergy)::bigint clergy,
    floor(greatest(inhabitants,0)::numeric*burgher)::bigint burgher
  from shares where noble is not null and inhabitants is not null
)
select 'Знать'::text,noble from counts union all
select 'Духовенство',clergy from counts union all
select 'Горожане',burgher from counts union all
select 'Крестьяне',greatest(inhabitants,0)-noble-clergy-burgher from counts
$$;
revoke all on function fauxlore.estate_population(text,bigint) from public,anon,authenticated;

create or replace function fauxlore.estate_tax_rate(target_state integer, target_estate text, cfg jsonb)
returns numeric language sql stable security invoker set search_path='' as $$
select coalesce((select rate from fauxlore.state_estate_tax_rates where state_id=target_state and estate=target_estate),
  nullif(cfg#>>array['estateTaxRates',target_estate],'')::numeric)
$$;
revoke all on function fauxlore.estate_tax_rate(integer,text,jsonb) from public,anon,authenticated;

create or replace function fauxlore.province_estate_gross_tax(target_province integer,target_state integer,share numeric,cfg jsonb)
returns table(estate text,population bigint,gross numeric)
language sql stable security invoker set search_path='' as $$
select e.estate,e.population,
  round(e.population::numeric*fauxlore.estate_tax_rate(target_state,e.estate,cfg)
    *coalesce((cfg#>>array['provinceModifiers',p.province_type,'tax'])::numeric,0)
    *greatest(0,least(100,coalesce(p.control,100)))::numeric/100
    *greatest(0,coalesce(p.development,100))::numeric/100
    *greatest(0,least(1,share)),2)
from fauxlore.provinces p cross join lateral fauxlore.estate_population(p.province_type,p.population) e
where p.id=target_province and p.kind='land'
$$;
revoke all on function fauxlore.province_estate_gross_tax(integer,integer,numeric,jsonb) from public,anon,authenticated;

create or replace function fauxlore.estate_tax_rates_api(path text,method text,body jsonb,request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a fauxlore.accounts; target_state integer; is_admin boolean; calendar_row fauxlore.game_calendar;
  cfg jsonb; selected_estate text; selected_rate numeric; previous fauxlore.operations; fingerprint text; result jsonb;
begin
  if path !~ '^(my|admin)/states/[0-9]+/estate-tax-rates$' or method not in ('GET','POST') then
    raise sqlstate 'P0002' using message='Метод API не найден'; end if;
  a:=fauxlore.current_account(); is_admin:=a.role='admin';
  if (path like 'admin/%') is distinct from is_admin then raise sqlstate '42501' using message='Недостаточно прав'; end if;
  target_state:=substring(path from '[0-9]+')::integer;
  if not exists(select 1 from fauxlore.state_profiles where state_id=target_state) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
  if not is_admin and not exists(select 1 from fauxlore.account_states where account_id=a.id and state_id=target_state) then
    raise sqlstate '42501' using message='Это государство не закреплено за вашим аккаунтом'; end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true;
  select config into cfg from fauxlore.economy_parameters where singleton=true;
  if method='GET' then
    return jsonb_build_object('state_id',target_state,'prestige',(select prestige from fauxlore.state_profiles where state_id=target_state),
      'groups',coalesce((select jsonb_agg(jsonb_build_object('estate',e.estate,
        'base_rate',(cfg#>>array['estateTaxRates',e.estate])::numeric,
        'rate',fauxlore.estate_tax_rate(target_state,e.estate,cfg),
        'changed_this_turn',coalesce(r.changed_year=calendar_row.year and r.changed_turn=calendar_row.turn,false)) order by e.estate)
        from unnest(array['Знать','Духовенство','Горожане','Крестьяне']) e(estate)
        left join fauxlore.state_estate_tax_rates r on r.state_id=target_state and r.estate=e.estate),'[]'::jsonb));
  end if;
  if request_id is null or jsonb_typeof(body) is distinct from 'object' or body-array['estate','rate']<>'{}'::jsonb or
     jsonb_typeof(body->'estate') is distinct from 'string' or jsonb_typeof(body->'rate') is distinct from 'number' then
    raise sqlstate '22023' using message='Некорректная ставка сословия'; end if;
  selected_estate:=body->>'estate'; selected_rate:=(body->>'rate')::numeric;
  if selected_estate not in ('Знать','Духовенство','Горожане','Крестьяне') or selected_rate<0 or selected_rate>10000 then
    raise sqlstate '22023' using message='Неизвестное сословие или ставка вне диапазона 0–10000 G'; end if;
  fingerprint:=md5(jsonb_build_array(method,path,body)::text);
  perform pg_advisory_xact_lock(hashtextextended(a.id::text||':'||request_id::text,0));
  select * into previous from fauxlore.operations o where o.account_id=a.id and o.request_id=estate_tax_rates_api.request_id;
  if found then
    if previous.fingerprint<>fingerprint then raise sqlstate '22023' using message='Идентификатор команды уже использован'; end if;
    return previous.result;
  end if;
  select * into calendar_row from fauxlore.game_calendar where singleton=true for share;
  if not is_admin and exists(select 1 from fauxlore.state_estate_tax_rates r where r.state_id=target_state and r.estate=selected_estate
      and r.changed_year=calendar_row.year and r.changed_turn=calendar_row.turn) then
    raise sqlstate '22023' using message='Эту ставку уже меняли в текущем ходу'; end if;
  if not is_admin then
    update fauxlore.state_profiles set prestige=prestige-3 where state_id=target_state and prestige>=3;
    if not found then raise sqlstate '22023' using message='Недостаточно ОП: изменение ставки стоит 3 ОП'; end if;
  end if;
  insert into fauxlore.state_estate_tax_rates(state_id,estate,rate,changed_year,changed_turn,changed_by)
    values(target_state,selected_estate,selected_rate,calendar_row.year,calendar_row.turn,a.id)
    on conflict(state_id,estate) do update set rate=excluded.rate,changed_year=excluded.changed_year,
      changed_turn=excluded.changed_turn,changed_by=excluded.changed_by,updated_at=now();
  result:=jsonb_build_object('state_id',target_state,'estate',selected_estate,'rate',selected_rate,
    'cost',case when is_admin then 0 else 3 end,'prestige',(select prestige from fauxlore.state_profiles where state_id=target_state));
  insert into fauxlore.operations(account_id,request_id,fingerprint,result)
    values(a.id,estate_tax_rates_api.request_id,fingerprint,result);
  return result;
end $$;
revoke all on function fauxlore.estate_tax_rates_api(text,text,jsonb,uuid) from public,anon,authenticated;

do $migration$
declare fn text; old_text text;
begin
  select pg_get_functiondef(p.oid) into fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='fauxlore_api';
  old_text:='if path in (''economy/config'',''admin/economy/config'') then';
  if fn is null or position(old_text in fn)=0 then raise exception 'Unexpected fauxlore_api dispatcher'; end if;
  fn:=replace(fn,old_text,
    'if path ~ ''^(my|admin)/states/[0-9]+/estate-tax-rates$'' then return fauxlore.estate_tax_rates_api(path,method,body,request_id); end if; '||old_text);
  execute fn;
end $migration$;
