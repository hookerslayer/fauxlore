create table fauxlore.admin_global_modifiers (
  id bigint generated always as identity primary key,
  target_kind text not null check(target_kind in ('state_group','trade_zone')),
  state_ids integer[] not null default '{}',
  trade_zone_id integer,
  modifier_key text not null,
  effect text not null,
  value numeric not null,
  unit text not null,
  scope text not null,
  condition_text text not null default '',
  source text not null,
  starts_year integer not null,
  starts_turn integer not null,
  expires_year integer,
  expires_turn integer,
  created_by bigint not null references fauxlore.accounts(id),
  created_at timestamptz not null default now(),
  check ((target_kind='state_group' and cardinality(state_ids)>0 and trade_zone_id is null)
      or (target_kind='trade_zone' and cardinality(state_ids)=0 and trade_zone_id is not null)),
  check ((expires_year is null)=(expires_turn is null))
);
create index admin_global_modifiers_zone_idx on fauxlore.admin_global_modifiers(trade_zone_id) where target_kind='trade_zone';
alter table fauxlore.admin_global_modifiers enable row level security;
revoke all on fauxlore.admin_global_modifiers from public,anon,authenticated;

create or replace function public.admin_global_modifiers_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; catalog jsonb; def jsonb; entry fauxlore.admin_global_modifiers;
  ids integer[]; zone_key integer; kind text; idx integer; val numeric; duration integer;
  current_year integer; current_turn integer; expiry bigint; label text;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if action='snapshot' then
    return jsonb_build_object(
      'zones',coalesce((select jsonb_agg(jsonb_build_object('id',z.id,'name',z.name) order by z.name)
        from fauxlore.map_categories z where z.layer='trade'),'[]'::jsonb),
      'assigned',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'kind',g.target_kind,
        'target_name',case when g.target_kind='trade_zone' then
          (select z.name from fauxlore.map_categories z where z.layer='trade' and z.id=g.trade_zone_id)
          else (select string_agg(s.name,', ' order by s.name) from fauxlore.map_categories s where s.layer='states' and s.id=any(g.state_ids)) end,
        'effect',g.effect,'value',g.value,'unit',g.unit,'source',g.source,
        'remaining_turns',case when g.expires_year is null then null else greatest(0,(g.expires_year*10000+g.expires_turn)-(cal.year*10000+cal.turn)) end)
        order by g.created_at desc) from fauxlore.admin_global_modifiers g cross join fauxlore.game_calendar cal),'[]'::jsonb));
  elsif action='delete' then
    delete from fauxlore.admin_global_modifiers where id=(payload->>'modifier_id')::bigint;
    if not found then raise sqlstate 'P0002' using message='Глобальный модификатор не найден'; end if;
    return jsonb_build_object('deleted',true);
  elsif action<>'assign' then
    raise sqlstate '22023' using message='Неизвестное действие конструктора модификаторов';
  end if;
  kind:=payload->>'target_kind';
  if kind not in ('state_group','trade_zone') then raise sqlstate '22023' using message='Выберите группу государств или торговую зону'; end if;
  idx:=(payload->>'definition_index')::integer;
  val:=(payload->>'value')::numeric;
  duration:=nullif(payload->>'duration_turns','')::integer;
  if idx is null or idx<0 or val is null or abs(val)>1000000000 or
    (duration is not null and (duration<1 or duration>10000)) then
    raise sqlstate '22023' using message='Проверьте эффект, значение и срок';
  end if;
  catalog:=fauxlore.admin_modifiers_api('snapshot','{}'::jsonb);
  def:=catalog->'definitions'->idx;
  if def is null then raise sqlstate '22023' using message='Эффект не найден'; end if;
  if kind='state_group' then
    if jsonb_typeof(payload->'state_ids') is distinct from 'array' then raise sqlstate '22023' using message='Выберите государства'; end if;
    select array_agg(distinct value::integer order by value::integer) into ids
      from jsonb_array_elements_text(payload->'state_ids') e(value);
    if cardinality(ids) is null or not exists(select 1 from fauxlore.map_categories s where s.layer='states' and s.id=any(ids))
      or (select count(*) from fauxlore.map_categories s where s.layer='states' and s.id=any(ids))<>cardinality(ids) then
      raise sqlstate '22023' using message='Группа содержит неизвестные государства'; end if;
  else
    ids:='{}';zone_key:=(payload->>'trade_zone_id')::integer;
    if not exists(select 1 from fauxlore.map_categories z where z.layer='trade' and z.id=zone_key) then
      raise sqlstate '22023' using message='Торговая зона не найдена'; end if;
  end if;
  select year,turn into current_year,current_turn from fauxlore.game_calendar where singleton=true;
  if duration is not null then expiry:=current_year::bigint*10000+current_turn+duration; end if;
  label:=left(coalesce(nullif(btrim(payload->>'source'),''),'Глобальное назначение администратора'),120);
  insert into fauxlore.admin_global_modifiers(target_kind,state_ids,trade_zone_id,modifier_key,effect,value,unit,scope,condition_text,
    source,starts_year,starts_turn,expires_year,expires_turn,created_by)
  values(kind,ids,zone_key,def->>'key',def->>'effect',val,def->>'unit',def->>'scope',coalesce(def->>'condition',''),
    label,current_year,current_turn,case when expiry is null then null else floor(expiry/10000)::integer end,
    case when expiry is null then null else mod(expiry,10000)::integer end,actor.id)
  returning * into entry;
  return jsonb_build_object('id',entry.id,'status','Активен');
end $$;
revoke all on function public.admin_global_modifiers_api(text,jsonb) from public,anon;
grant execute on function public.admin_global_modifiers_api(text,jsonb) to authenticated;

create or replace function fauxlore.state_permanent_modifiers(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with state_row as (
  select sp.principles,sp.state_id from fauxlore.state_profiles sp where sp.state_id=target_state
), present_groups as (
  select distinct v.layer source_kind,c.name source_key
  from fauxlore.province_values owner_value
  join fauxlore.provinces p on p.id=owner_value.province_id and p.kind='land'
  join fauxlore.province_values v on v.province_id=p.id and v.layer in ('races','religions')
  join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id
  where owner_value.layer='states' and owner_value.category_id=target_state
), active as (
  select d.* from fauxlore.permanent_modifier_definitions d cross join state_row s
  where (d.source_kind in ('authority','structure','economy','military') and
    case d.source_kind when 'authority' then s.principles->>'authority' when 'structure' then s.principles->>'structure'
      when 'economy' then s.principles->>'economy' when 'military' then s.principles->>'military' end=d.source_key)
    or (d.source_kind in ('race','religion') and exists(select 1 from present_groups g where g.source_kind=d.source_kind||'s' and g.source_key=d.source_key))
), modifiers as (
  select d.source_kind,d.source_key,d.value,d.modifier_key,d.effect,d.unit,d.scope,d.condition_text,
    case d.source_kind when 'authority' then 1 when 'structure' then 2 when 'economy' then 3 when 'military' then 4 when 'race' then 5 else 6 end sort_order,
    null::integer target_province_id,null::integer target_trade_zone_id,null::integer expires_year,null::integer expires_turn
  from active d
  union all
  select 'admin',a.source,a.value,a.modifier_key,a.effect,a.unit,
    case when a.province_id is null then 'Государство' else 'Провинция' end,'',7,a.province_id,null::integer,a.expires_year,a.expires_turn
  from fauxlore.admin_modifier_assignments a cross join fauxlore.game_calendar g
  where a.state_id=target_state
    and (a.province_id is null or exists(select 1 from fauxlore.province_values owner where owner.province_id=a.province_id and owner.layer='states' and owner.category_id=target_state))
    and (a.expires_year is null or (g.year*10000+g.turn)<(a.expires_year*10000+a.expires_turn))
  union all
  select 'admin_global',gm.source,gm.value,gm.modifier_key,gm.effect,gm.unit,gm.scope,gm.condition_text,8,
    null::integer,gm.trade_zone_id,gm.expires_year,gm.expires_turn
  from fauxlore.admin_global_modifiers gm cross join fauxlore.game_calendar g
  where (gm.target_kind='state_group' and target_state=any(gm.state_ids)
      or gm.target_kind='trade_zone' and exists(
        select 1 from fauxlore.province_values owner
        join fauxlore.province_values zone on zone.province_id=owner.province_id and zone.layer='trade' and zone.category_id=gm.trade_zone_id
        where owner.layer='states' and owner.category_id=target_state))
    and (gm.expires_year is null or (g.year*10000+g.turn)<(gm.expires_year*10000+gm.expires_turn))
)
select coalesce(jsonb_agg(jsonb_build_object(
  'source_kind',source_kind,'source',source_key,'key',modifier_key,'effect',effect,'value',value,
  'unit',unit,'scope',scope,'condition',condition_text,'status','Активен',
  'duration',case when expires_year is null then 'Постоянный' else 'До хода '||expires_turn||' ('||expires_year||')' end,
  'target_province_id',target_province_id,'target_trade_zone_id',target_trade_zone_id)
  order by sort_order,source_key,modifier_key), '[]'::jsonb) from modifiers
$$;
revoke all on function fauxlore.state_permanent_modifiers(integer) from public,anon,authenticated;

do $migration$ declare fn text; marker text; addition text; begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  marker:='scope_value:=row_value->>''scope''; condition_value:=coalesce(row_value->>''condition'','''');';
  addition:=marker||E'\n    if row_value->>''target_trade_zone_id'' is not null and target_province is not null and not exists(\n      select 1 from fauxlore.province_values z where z.province_id=target_province and z.layer=''trade''\n        and z.category_id=(row_value->>''target_trade_zone_id'')::integer) then continue; end if;';
  if position(marker in fn)=0 then raise exception 'Trade zone modifier insertion point not found'; end if;
  execute replace(fn,marker,addition);
end $migration$;
notify pgrst,'reload schema';
