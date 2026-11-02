create table fauxlore.instant_resource_modifier_events (
 id bigint generated always as identity primary key,
 state_id integer not null references fauxlore.state_profiles(state_id) on delete cascade,
 resource text not null check(resource in ('prestige','treasury')),
 estate text, value integer not null, source text not null,
 created_by bigint not null references fauxlore.accounts(id),created_at timestamptz not null default now()
);
alter table fauxlore.instant_resource_modifier_events enable row level security;
revoke all on fauxlore.instant_resource_modifier_events from public,anon,authenticated;
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=replace(pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure),chr(13),'');
 marker:=$old$      if not found then raise sqlstate '22023' using message='Недостаточно ресурса или Казна не найдена'; end if;
    else$old$;
 replacement:=$new$      if not found then raise sqlstate '22023' using message='Недостаточно ресурса или Казна не найдена'; end if;
      insert into fauxlore.instant_resource_modifier_events(state_id,resource,estate,value,source,created_by) values(state_key,payload->>'resource',case when payload->>'resource'='treasury' then payload->>'estate' else null end,value_key::integer,coalesce(nullif(left(btrim(payload->>'source'),120),''),'Разовое назначение'),actor.id);
    else$new$;
 if position(marker in fn)=0 then raise exception 'resource history assignment hook missing'; end if; execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
 marker:=$old$ from modifiers$old$;
 replacement:=$new$ || coalesce((select jsonb_agg(jsonb_build_object('source_kind','admin_history','source',e.source,'key','instant_resource_'||e.resource,'effect',case e.resource when 'treasury' then 'Разовое изменение Казны · '||e.estate else 'Разовое изменение Престижа' end,'value',e.value,'unit',case e.resource when 'treasury' then 'G' else 'ОП' end,'scope','Государство','condition','','status','Применён','duration','Разовое','target_province_id',null,'target_trade_zone_id',null) order by e.created_at desc,e.id desc) from fauxlore.instant_resource_modifier_events e where e.state_id=target_state),'[]'::jsonb) from modifiers$new$;
 if position(marker in fn)=0 then raise exception 'resource history projection hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
notify pgrst,'reload schema';
