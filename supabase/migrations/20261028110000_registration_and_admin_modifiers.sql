-- Apply the registered state's official race and religion to every province
-- chosen in the application, and support temporary administrator-assigned effects.
create or replace function fauxlore.apply_application_official_groups()
returns trigger language plpgsql security definer set search_path='' as $function$
begin
  if new.status='Принято' and old.status is distinct from new.status then
    insert into fauxlore.province_values(province_id,layer,category_id)
      select unnest(new.province_ids),'races',new.race_id
      on conflict(province_id,layer) do update set category_id=excluded.category_id;
    insert into fauxlore.province_values(province_id,layer,category_id)
      select unnest(new.province_ids),'religions',new.religion_id
      on conflict(province_id,layer) do update set category_id=excluded.category_id;
  end if;
  return new;
end $function$;
revoke all on function fauxlore.apply_application_official_groups() from public,anon,authenticated;
drop trigger if exists state_application_official_groups on fauxlore.state_applications;
create trigger state_application_official_groups after update of status on fauxlore.state_applications
for each row execute function fauxlore.apply_application_official_groups();

create table if not exists fauxlore.admin_modifier_assignments(
  id bigint generated always as identity primary key,
  state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
  province_id integer references fauxlore.provinces(id) on delete cascade,
  modifier_key text not null,
  effect text not null,
  value numeric not null,
  unit text not null,
  source text not null,
  starts_year integer not null,
  starts_turn integer not null,
  expires_year integer,
  expires_turn integer,
  created_by bigint not null references fauxlore.accounts(id),
  created_at timestamptz not null default now(),
  check((expires_year is null)=(expires_turn is null)),
  check(expires_year is null or (expires_year*10000+expires_turn)>(starts_year*10000+starts_turn))
);
create index if not exists admin_modifier_assignments_state_idx on fauxlore.admin_modifier_assignments(state_id,expires_year,expires_turn);
alter table fauxlore.admin_modifier_assignments enable row level security;
revoke all on fauxlore.admin_modifier_assignments from public,anon,authenticated;

create or replace function fauxlore.state_permanent_modifiers(target_state integer)
returns jsonb language sql stable security definer set search_path='' as $$
with state_row as (
  select sp.principles,sp.state_id,c.name state_name
  from fauxlore.state_profiles sp join fauxlore.map_categories c on c.layer='states' and c.id=sp.state_id
  where sp.state_id=target_state
), present_groups as (
  select distinct v.layer source_kind,c.name source_key
  from fauxlore.province_values owner_value
  join fauxlore.provinces p on p.id=owner_value.province_id and p.kind='land'
  join fauxlore.province_values v on v.province_id=p.id and v.layer in ('races','religions')
  join fauxlore.map_categories c on c.layer=v.layer and c.id=v.category_id
  where owner_value.layer='states' and owner_value.category_id=target_state
), active as (
  select d.*,case d.source_kind
    when 'authority' then s.principles->>'authority' when 'structure' then s.principles->>'structure'
    when 'economy' then s.principles->>'economy' when 'military' then s.principles->>'military' else d.source_key end active_source
  from fauxlore.permanent_modifier_definitions d cross join state_row s
  where (d.source_kind in ('authority','structure','economy','military') and
    case d.source_kind when 'authority' then s.principles->>'authority' when 'structure' then s.principles->>'structure'
      when 'economy' then s.principles->>'economy' when 'military' then s.principles->>'military' end=d.source_key)
    or (d.source_kind in ('race','religion') and exists(select 1 from present_groups g where g.source_kind=d.source_kind||'s' and g.source_key=d.source_key))
), modifiers as (
  select source_kind,source_key,value,modifier_key,effect,unit,scope,condition_text,sort_order,null::integer target_province_id
  from active cross join lateral (select case source_kind when 'authority' then 1 when 'structure' then 2 when 'economy' then 3 when 'military' then 4 when 'race' then 5 else 6 end sort_order) ordering
  union all
  select 'admin',a.source,a.value,a.modifier_key,a.effect,a.unit,
    case when a.province_id is null then 'Государство' else 'Провинция' end,'',7,a.province_id
  from fauxlore.admin_modifier_assignments a cross join fauxlore.game_calendar g
  where a.state_id=target_state
    and (a.province_id is null or exists(select 1 from fauxlore.province_values owner where owner.province_id=a.province_id and owner.layer='states' and owner.category_id=target_state))
    and (a.expires_year is null or (g.year*10000+g.turn)<(a.expires_year*10000+a.expires_turn))
)
select coalesce(jsonb_agg(jsonb_build_object(
  'source_kind',source_kind,'source',source_key,'key',modifier_key,'effect',effect,'value',value,
  'unit',unit,'scope',scope,'condition',condition_text,'status','Активен',
  'duration',case when source_kind='admin' and target_province_id is not null then 'Провинция' else 'Постоянный' end,
  'target_province_id',target_province_id)
  order by sort_order,source_key,modifier_key), '[]'::jsonb) from modifiers
$$;
revoke all on function fauxlore.state_permanent_modifiers(integer) from public,anon,authenticated;

do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  marker:='scope_value:=row_value->>''scope''; condition_value:=coalesce(row_value->>''condition'','''');';
  if position(marker in fn)=0 then raise exception 'Modifier total insertion point is missing'; end if;
  replacement:=marker||E'\n    if row_value->>''source_kind''=''admin'' then\n      if row_value->>''target_province_id'' is not null and\n        (target_province is null or (row_value->>''target_province_id'')::integer<>target_province) then continue; end if;\n    end if;';
  execute replace(fn,marker,replacement);
end $migration$;

create or replace function fauxlore.admin_modifiers_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; state_key integer; province_key integer; definition_index integer; def record;
  value_key numeric; duration_key integer; calendar_row fauxlore.game_calendar; expiry_ordinal bigint; modifier_key bigint;
begin
  actor:=fauxlore.current_account();
  if coalesce(actor.role,'')<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if action='snapshot' then
    return jsonb_build_object(
      'states',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name) order by c.name) from fauxlore.map_categories c where c.layer='states'),'[]'::jsonb),
      'provinces',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'state_id',owner.category_id,'state_name',s.name) order by s.name,p.name)
        from fauxlore.province_values owner join fauxlore.provinces p on p.id=owner.province_id join fauxlore.map_categories s on s.layer='states' and s.id=owner.category_id
        where owner.layer='states' and p.kind='land'),'[]'::jsonb),
      'definitions',coalesce((select jsonb_agg(jsonb_build_object('source_kind',d.source_kind,'source',d.source_key,'key',d.modifier_key,'effect',d.effect,'value',d.value,'unit',d.unit,'scope',d.scope,'condition',d.condition_text)
        order by d.effect,d.source_kind,d.source_key,d.modifier_key,d.scope,d.condition_text) from fauxlore.permanent_modifier_definitions d where d.modifier_key<>'spy_growth' and d.condition_text<>'Максимум'),'[]'::jsonb),
      'assigned',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'target_name',case when a.province_id is null then s.name else p.name||' · '||s.name end,
        'effect',a.effect,'value',a.value,'unit',a.unit,'remaining_turns',case when a.expires_year is null then null else greatest(0,(a.expires_year*10000+a.expires_turn)-(g.year*10000+g.turn)) end)
        order by a.created_at desc) from fauxlore.admin_modifier_assignments a cross join fauxlore.game_calendar g join fauxlore.map_categories s on s.layer='states' and s.id=a.state_id
        left join fauxlore.provinces p on p.id=a.province_id),'[]'::jsonb));
  elsif action='assign' then
    state_key:=(payload->>'state_id')::integer; province_key:=nullif(payload->>'province_id','')::integer;
    definition_index:=(payload->>'definition_index')::integer; value_key:=(payload->>'value')::numeric;
    duration_key:=nullif(payload->>'duration_turns','')::integer;
    if payload->>'target_kind' not in ('state','province') or state_key is null or definition_index<0 or value_key is null
      or abs(value_key)>1000000000 or (duration_key is not null and (duration_key<1 or duration_key>10000))
      or (payload->>'target_kind'='province' and province_key is null)
      or (payload->>'target_kind'='state' and province_key is not null) then
      raise sqlstate '22023' using message='Проверьте объект, значение и срок модификатора'; end if;
    select * into calendar_row from fauxlore.game_calendar where singleton=true;
    select * into def from fauxlore.permanent_modifier_definitions d where d.modifier_key<>'spy_growth' and d.condition_text<>'Максимум'
      order by d.effect,d.source_kind,d.source_key,d.modifier_key,d.scope,d.condition_text offset definition_index limit 1;
    if not found then raise sqlstate '22023' using message='Модификатор не найден'; end if;
    if not exists(select 1 from fauxlore.map_categories c where c.layer='states' and c.id=state_key) then raise sqlstate 'P0002' using message='Государство не найдено'; end if;
    if province_key is not null and not exists(select 1 from fauxlore.province_values owner where owner.layer='states' and owner.category_id=state_key and owner.province_id=province_key) then
      raise sqlstate '22023' using message='Провинция не принадлежит выбранному государству'; end if;
    if duration_key is not null then expiry_ordinal:=calendar_row.year::bigint*10000+calendar_row.turn+duration_key; end if;
    insert into fauxlore.admin_modifier_assignments(state_id,province_id,modifier_key,effect,value,unit,source,starts_year,starts_turn,expires_year,expires_turn,created_by)
    values(state_key,province_key,def.modifier_key,def.effect,value_key,def.unit,def.source_key,calendar_row.year,calendar_row.turn,
      case when expiry_ordinal is null then null else floor(expiry_ordinal/10000)::integer end,
      case when expiry_ordinal is null then null else mod(expiry_ordinal,10000)::integer end,actor.id)
    returning id into modifier_key;
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
    return jsonb_build_object('id',modifier_key,'status','Активен');
  elsif action='delete' then
    delete from fauxlore.admin_modifier_assignments where id=(payload->>'modifier_id')::bigint;
    if not found then raise sqlstate 'P0002' using message='Назначение модификатора не найдено'; end if;
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
    return jsonb_build_object('deleted',true);
  end if;
  raise sqlstate '22023' using message='Неизвестное действие конструктора модификаторов';
end $function$;
revoke all on function fauxlore.admin_modifiers_api(text,jsonb) from public,anon,authenticated;
grant execute on function fauxlore.admin_modifiers_api(text,jsonb) to authenticated;
create or replace function public.admin_modifiers_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language sql security invoker set search_path=pg_catalog,fauxlore as $$
  select fauxlore.admin_modifiers_api(action,payload);
$$;
revoke all on function public.admin_modifiers_api(text,jsonb) from public,anon;
grant execute on function public.admin_modifiers_api(text,jsonb) to authenticated;
notify pgrst,'reload schema';
