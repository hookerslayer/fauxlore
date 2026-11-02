create table fauxlore.instant_modifier_events (
 id bigint generated always as identity primary key,
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 province_id integer not null references fauxlore.provinces(id) on delete cascade,
 effect_key text not null check(effect_key in ('population','development')),
 value integer not null, source text not null, created_by bigint not null references fauxlore.accounts(id),
 created_at timestamptz not null default now()
);
alter table fauxlore.instant_modifier_events enable row level security;
revoke all on fauxlore.instant_modifier_events from public,anon,authenticated;
create function public.instant_modifier_api(payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; sid integer; province_key integer; group_key integer; effect_key text; scope_key text; amount numeric; ids integer[]; label text; row_value record;
begin
 actor:=fauxlore.current_account(); sid:=nullif(payload->>'state_id','')::integer;
 if actor.id is null or (actor.role<>'admin' and not fauxlore.judge_can_review(actor.id,sid)) then raise sqlstate '42501' using message='Нет доступа к государству'; end if;
 effect_key:=payload->>'effect';scope_key:=coalesce(payload->>'scope','state');amount:=nullif(payload->>'value','')::numeric;province_key:=nullif(payload->>'province_id','')::integer;group_key:=nullif(payload->>'group_id','')::integer;
 label:=coalesce(nullif(left(btrim(payload->>'source'),120),''),'Разовое назначение');
 if effect_key not in ('population','development') or scope_key not in ('state','province','capital','cities','regions','race','religion') or amount is null or amount=0 or amount<>trunc(amount) or abs(amount)>1000000000 or (scope_key='province' and province_key is null) or (scope_key in ('race','religion') and group_key is null) then raise sqlstate '22023' using message='Проверьте показатель, область и целое значение'; end if;
 perform 1 from fauxlore.game_calendar where singleton for share;
 select array_agg(p.id order by p.id) into ids from fauxlore.provinces p join fauxlore.province_values o on o.province_id=p.id and o.layer='states' and o.category_id=sid
 where p.kind='land' and (scope_key='state' or scope_key='province' and p.id=province_key or scope_key='capital' and p.province_type='Столичная' or scope_key='cities' and p.province_type in ('Столичная','Городская') or scope_key='regions' and p.province_type='Регион' or scope_key in ('race','religion') and exists(select 1 from fauxlore.province_values g where g.province_id=p.id and g.layer=case scope_key when 'race' then 'races' else 'religions' end and g.category_id=group_key));
 if coalesce(cardinality(ids),0)=0 then raise sqlstate '22023' using message='В области действия нет подходящих провинций'; end if;
 for row_value in select p.id,p.population,p.development from fauxlore.provinces p where p.id=any(ids) order by p.id for update loop
  if effect_key='population' and (row_value.population+amount<0 or row_value.population+amount>2147483647) or effect_key='development' and (row_value.development+amount<0 or row_value.development+amount>1000000) then raise sqlstate '22023' using message='Изменение выходит за пределы показателя провинции'; end if;
 end loop;
 if effect_key='population' then update fauxlore.provinces set population=population+amount where id=any(ids); else update fauxlore.provinces set development=development+amount where id=any(ids); end if;
 insert into fauxlore.instant_modifier_events(state_id,province_id,effect_key,value,source,created_by) select sid,id,effect_key,amount::integer,label,actor.id from unnest(ids) id;
 update fauxlore._settings set value_json=to_jsonb((value_json#>>'{}')::bigint+1) where key='data_revision';
 return jsonb_build_object('applied',true,'province_count',cardinality(ids));
end $$;
revoke all on function public.instant_modifier_api(jsonb) from public,anon;
grant execute on function public.instant_modifier_api(jsonb) to authenticated;
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
 marker:=$old$      if item ? 'resource' then$old$;
 replacement:=$new$      if item ? 'instant_effect' then
        perform public.instant_modifier_api(item||jsonb_build_object('effect',item->>'instant_effect','state_id',verdict_state));
      elsif item ? 'resource' then$new$;
 if position(marker in fn)=0 then raise exception 'wall instant effect hook missing'; end if; execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.wall_verdict_many(jsonb)'::regprocedure);
 marker:=$old$      if item ? 'resource' then$old$;
 replacement:=$new$      if item ? 'instant_effect' then
        perform public.instant_modifier_api(item||jsonb_build_object('effect',item->>'instant_effect','state_id',sid));
      elsif item ? 'resource' then$new$;
 if position(marker in fn)=0 then raise exception 'multi-state instant effect hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
