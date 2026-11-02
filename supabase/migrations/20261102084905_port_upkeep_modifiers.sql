alter table fauxlore.admin_modifier_assignments drop constraint admin_modifier_assignments_target_scope_check;
alter table fauxlore.admin_modifier_assignments add constraint admin_modifier_assignments_target_scope_check check(target_scope in ('state','province','capital','cities','regions','race','religion','marker'));
alter table fauxlore.admin_modifier_assignments add column target_marker_id bigint references fauxlore.map_markers(id) on delete cascade;
insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text) values('constructor','Назначение','port_upkeep','Содержание портов',0,'%','Государство','');
do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.admin_modifiers_api(text,jsonb)'::regprocedure);
 marker:=$old$not in ('state','province','capital','cities','regions','race','religion')$old$;
 if position(marker in fn)=0 then raise exception 'port scope list hook missing'; end if;
 fn:=replace(fn,marker,$new$not in ('state','province','capital','cities','regions','race','religion','marker')$new$);
 marker:=$old$    update fauxlore.admin_modifier_assignments set modifier_key=$old$;
 replacement:=$new$    if payload->>'scope'='marker' and (def.modifier_key<>'port_upkeep' or not exists(select 1 from fauxlore.map_markers m left join fauxlore.military_port_builds b on b.marker_id=m.id where m.id=nullif(payload->>'marker_id','')::bigint and m.type='port' and coalesce(m.state_id,b.state_id)=state_key)) then raise sqlstate '22023' using message='Порт не принадлежит выбранному государству'; end if;
    update fauxlore.admin_modifier_assignments set target_marker_id=case when payload->>'scope'='marker' then (payload->>'marker_id')::bigint else null end,modifier_key=$new$;
 if position(marker in fn)=0 then raise exception 'port scope assignment hook missing'; end if;fn:=replace(fn,marker,replacement);
 marker:=$old$      'groups',coalesce((select jsonb_agg($old$;
 replacement:=$new$      'ports',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'state_id',coalesce(m.state_id,b.state_id)) order by m.name,m.id) from fauxlore.map_markers m left join fauxlore.military_port_builds b on b.marker_id=m.id where m.type='port' and coalesce(m.state_id,b.state_id) is not null and (actor.role='admin' or fauxlore.judge_can_review(actor.id,coalesce(m.state_id,b.state_id)))),'[]'::jsonb),
      'groups',coalesce((select jsonb_agg($new$;
 if position(marker in fn)=0 then raise exception 'port catalog hook missing'; end if; execute replace(fn,marker,replacement);
 fn:=pg_get_functiondef('fauxlore.state_permanent_modifiers(integer)'::regprocedure);
 marker:=$old$when 'religion' then 'Область:Религия:'||a.target_group_id end$old$;
 replacement:=$new$when 'religion' then 'Область:Религия:'||a.target_group_id when 'marker' then 'Область:Порт:'||a.target_marker_id end$new$;
 if position(marker in fn)=0 then raise exception 'port projection hook missing'; end if; execute replace(fn,marker,replacement);
end $migration$;
create or replace function fauxlore.port_upkeep(target_state integer) returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce(sum(floor(200*fauxlore.state_cost_multiplier(target_state)*greatest(0,1+fauxlore.state_permanent_modifier_total(target_state,array['port_upkeep'],null,null)+coalesce((select sum(a.value) from fauxlore.admin_modifier_assignments a cross join fauxlore.game_calendar g where a.state_id=target_state and a.modifier_key='port_upkeep' and a.target_scope='marker' and a.target_marker_id=m.id and (a.expires_year is null or (g.year*10000+g.turn)<(a.expires_year*10000+a.expires_turn))),0)))),0)
 from fauxlore.map_markers m left join fauxlore.military_port_builds b on b.marker_id=m.id
 where m.type='port' and coalesce(m.state_id,b.state_id)=target_state
$$;
revoke all on function fauxlore.port_upkeep(integer) from public,anon,authenticated;
notify pgrst,'reload schema';
