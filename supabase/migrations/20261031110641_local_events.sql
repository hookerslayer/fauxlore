-- Local events are independent of ownership; their modifiers follow the current owner.
create table fauxlore.local_events (
  id bigint generated always as identity primary key,
  province_id integer not null references fauxlore.provinces(id) on delete cascade,
  title text not null check (length(title) between 1 and 120),
  description text not null check (length(description)<=4000),
  remaining_turns integer check (remaining_turns is null or remaining_turns>=0),
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  created_by bigint not null references fauxlore.accounts(id)
);
create table fauxlore.local_event_effects (
  id bigint generated always as identity primary key,
  event_id bigint not null references fauxlore.local_events(id) on delete cascade,
  scope text not null check (scope in ('province','state')),
  modifier_key text not null,
  effect text not null,
  unit text not null,
  value numeric not null check (abs(value)<=1000000000)
);
create index local_events_active_province_idx on fauxlore.local_events(province_id) where ended_at is null;
create index local_event_effects_event_idx on fauxlore.local_event_effects(event_id);
alter table fauxlore.local_events enable row level security;
alter table fauxlore.local_event_effects enable row level security;
revoke all on fauxlore.local_events,fauxlore.local_event_effects from public,anon,authenticated;

-- Reuse the existing modifier pipeline, resolving ownership at read time.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
  old_fragment:=$old$), '[]'::jsonb) from modifiers$old$;
  new_fragment:=$new$), '[]'::jsonb) || coalesce((
    select jsonb_agg(jsonb_build_object('source_kind','admin','source',e.title,'key',f.modifier_key,
      'effect',f.effect,'value',f.value,'unit',f.unit,
      'scope',case f.scope when 'province' then 'Провинция' else 'Государство' end,
      'condition','','status','Активен',
      'duration',case when e.remaining_turns is null then 'Постоянный' else e.remaining_turns||' ход.' end,
      'target_province_id',case when f.scope='province' then e.province_id else null end,
      'target_trade_zone_id',null,'local_event_id',e.id) order by e.id,f.id)
    from fauxlore.local_events e join fauxlore.local_event_effects f on f.event_id=e.id
    join fauxlore.province_values v on v.layer='states' and v.province_id=e.province_id and v.category_id=target_state
    where e.ended_at is null), '[]'::jsonb) from modifiers$new$;
  if position(old_fragment in fn)=0 then raise exception 'Modifier pipeline changed'; end if;
  execute replace(fn,old_fragment,new_fragment);
end $migration$;

-- The last AFTER ROW trigger keeps final-turn effects active during all turn calculations.
create function fauxlore.advance_local_events() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if (new.year,new.turn) is not distinct from (old.year,old.turn) then return new; end if;
  update fauxlore.local_events set remaining_turns=remaining_turns-1,
    ended_at=case when remaining_turns=1 then now() else null end
    where ended_at is null and remaining_turns is not null;
  return new;
end $$;
revoke all on function fauxlore.advance_local_events() from public,anon,authenticated;
create trigger zzzzzzzzz_local_events_after_turn after update of year,turn on fauxlore.game_calendar
  for each row execute function fauxlore.advance_local_events();

create function public.local_events_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; event_key bigint; row_value jsonb; def record; scope_value text; value_number numeric;
  province_key integer; duration_value integer; title_value text; description_value text;
begin
  if action='projection' then
    province_key:=(payload->>'province_id')::integer;
    return coalesce((select jsonb_agg(jsonb_build_object('source_kind','admin','key',f.modifier_key,'value',f.value,
      'target_province_id',case when f.scope='province' then e.province_id else null end))
      from fauxlore.local_events e join fauxlore.local_event_effects f on f.event_id=e.id
      where e.ended_at is null and ((f.scope='province' and e.province_id=province_key)
        or (f.scope='state' and exists(select 1 from fauxlore.province_values owner
          join fauxlore.province_values event_owner on event_owner.layer='states' and event_owner.category_id=owner.category_id
          where owner.layer='states' and owner.province_id=province_key and event_owner.province_id=e.province_id)))), '[]'::jsonb);
  end if;
  if action='list' then
    return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'province_id',e.province_id,'province_name',p.name,
      'title',e.title,'description',e.description,'remaining_turns',e.remaining_turns,
      'effects',coalesce((select jsonb_agg(jsonb_build_object('scope',f.scope,'effect',f.effect,'unit',f.unit,'value',f.value) order by f.id)
        from fauxlore.local_event_effects f where f.event_id=e.id),'[]'::jsonb)) order by e.id)
      from fauxlore.local_events e join fauxlore.provinces p on p.id=e.province_id where e.ended_at is null),'[]'::jsonb);
  end if;
  actor:=fauxlore.current_account();
  if coalesce(actor.role,'')<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
  if action='catalog' then
    return jsonb_build_object(
      'provinces',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.name,p.id)
        from fauxlore.provinces p where p.kind='land'),'[]'::jsonb),
      'definitions',coalesce((select jsonb_agg(jsonb_build_object('key',d.modifier_key,'effect',d.effect,'unit',d.unit)
        order by d.effect,d.modifier_key,d.unit) from (select distinct modifier_key,effect,unit from fauxlore.permanent_modifier_definitions
          where modifier_key<>'spy_growth' and condition_text<>'Максимум' and unit not in ('статус')) d),'[]'::jsonb));
  elsif action='create' then
    perform 1 from fauxlore.game_calendar where singleton for share;
    province_key:=(payload->>'province_id')::integer;
    duration_value:=nullif(payload->>'duration_turns','')::integer;
    title_value:=btrim(payload->>'title'); description_value:=btrim(coalesce(payload->>'description',''));
    if province_key is null or not exists(select 1 from fauxlore.provinces where id=province_key and kind='land')
      or title_value is null or length(title_value) not between 1 and 120 or length(description_value)>4000
      or (duration_value is not null and duration_value not between 1 and 10000)
      or jsonb_typeof(payload->'effects') is distinct from 'array'
      or jsonb_array_length(payload->'effects') not between 1 and 30 then
      raise sqlstate '22023' using message='Проверьте провинцию, название, эффекты и срок события'; end if;
    insert into fauxlore.local_events(province_id,title,description,remaining_turns,created_by)
      values(province_key,title_value,description_value,duration_value,actor.id) returning id into event_key;
    for row_value in select value from jsonb_array_elements(payload->'effects') loop
      scope_value:=row_value->>'scope'; value_number:=(row_value->>'value')::numeric;
      if scope_value not in ('province','state') or value_number is null or abs(value_number)>1000000000 then
        raise sqlstate '22023' using message='Некорректный эффект события'; end if;
      select d.modifier_key,d.effect,d.unit into def from fauxlore.permanent_modifier_definitions d
        where d.modifier_key=row_value->>'key' and d.effect=row_value->>'effect' and d.unit=row_value->>'unit'
          and d.modifier_key<>'spy_growth' and d.condition_text<>'Максимум' and d.unit<>'статус' limit 1;
      if not found then raise sqlstate '22023' using message='Эффект отсутствует в каталоге'; end if;
      if scope_value='province' and def.modifier_key not in ('tax_efficiency','production','trade_influence','population_growth','recruit_growth','recruit_limit','development') then
        raise sqlstate '22023' using message='Этот эффект доступен только для государства'; end if;
      insert into fauxlore.local_event_effects(event_id,scope,modifier_key,effect,unit,value)
        values(event_key,scope_value,def.modifier_key,def.effect,def.unit,value_number);
    end loop;
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
    return jsonb_build_object('id',event_key);
  elsif action='end' then
    update fauxlore.local_events set ended_at=now() where id=(payload->>'event_id')::bigint and ended_at is null;
    if not found then raise sqlstate 'P0002' using message='Активное событие не найдено'; end if;
    update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
    return jsonb_build_object('ended',true);
  end if;
  raise sqlstate '22023' using message='Неизвестное действие';
end $$;
revoke all on function public.local_events_api(text,jsonb) from public;
grant execute on function public.local_events_api(text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
