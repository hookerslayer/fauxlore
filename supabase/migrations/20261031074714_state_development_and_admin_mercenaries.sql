create or replace function public.state_development_growth_api(target_state integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; p record; growth numeric; cap numeric; result jsonb := '[]'::jsonb;
begin
 actor:=fauxlore.current_account();
 if actor.id is null or (actor.role is distinct from 'admin' and not exists(select 1 from fauxlore.account_states where account_id=actor.id and state_id=target_state)) then raise sqlstate '42501' using message='Нет доступа к государству'; end if;
 for p in select pr.id,pr.development,pr.province_type,r.name resource_name from fauxlore.provinces pr join fauxlore.province_values own on own.province_id=pr.id and own.layer='states' and own.category_id=target_state left join fauxlore.province_values rv on rv.province_id=pr.id and rv.layer='resources' left join fauxlore.map_categories r on r.layer='resources' and r.id=rv.category_id where pr.kind='land' loop
  growth:=fauxlore.state_permanent_modifier_total(target_state,array['development','urban_development','regional_development','forest_development','livestock_development','metal_development','precious_development','ephemera_development'],p.id,p.resource_name);
  cap:=null;
  if p.province_type='Регион' then select min((m->>'value')::numeric) into cap from jsonb_array_elements(fauxlore.state_permanent_modifiers(target_state)) m where m->>'key'='regional_development_cap' and m->>'condition'='Максимум'; end if;
  select least(coalesce(cap,1e12),min((m->>'value')::numeric)) into cap from jsonb_array_elements(fauxlore.state_permanent_modifiers(target_state)) m where m->>'key'='development_cap' and m->>'condition'='Максимум';
  growth:=case when growth<=0 then 0 else least(growth,coalesce(cap,growth)) end;
  result:=result||jsonb_build_array(jsonb_build_object('id',p.id,'development',p.development,'growth',growth));
 end loop;
 return result;
end $$;
revoke all on function public.state_development_growth_api(integer) from public,anon;
grant execute on function public.state_development_growth_api(integer) to authenticated;

create or replace function public.admin_mercenaries_api(action text,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor fauxlore.accounts; group_key bigint; group_row fauxlore.mercenary_groups;
begin
 actor:=fauxlore.current_account();
 if actor.id is null or actor.role is distinct from 'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
 if action='snapshot' then
  return jsonb_build_object('groups',coalesce((select jsonb_agg(to_jsonb(g)||jsonb_build_object('city_name',p.name,'hired_by',s.name) order by g.id) from fauxlore.mercenary_groups g join fauxlore.provinces p on p.id=g.city_province_id left join lateral (select c.name from fauxlore.military_formations f join fauxlore.map_categories c on c.layer='states' and c.id=f.state_id where f.mercenary_group_id=g.id and f.active order by f.id limit 1) s on true where g.active),'[]'::jsonb), 'cities',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name) order by p.name) from fauxlore.provinces p where exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.type in ('city','capital'))),'[]'::jsonb), 'catalog',coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'name',u.name) order by u.name) from fauxlore.military_unit_catalog u where u.domain='land' and u.active),'[]'::jsonb));
 elsif action='create' then
  return fauxlore.military_actions_extra('admin_mercenary',null,payload);
 elsif action='delete' then
  group_key:=(payload->>'group_id')::bigint;
  select * into group_row from fauxlore.mercenary_groups where id=group_key and active for update;
  if not found then raise sqlstate 'P0002' using message='Группа не найдена'; end if;
  update fauxlore.military_formations set active=false where mercenary_group_id=group_key and active;
  update fauxlore.mercenary_groups set active=false where id=group_key;
  return jsonb_build_object('ok',true);
 end if;
 raise sqlstate '22023' using message='Неизвестное действие';
end $$;
revoke all on function public.admin_mercenaries_api(text,jsonb) from public,anon;
grant execute on function public.admin_mercenaries_api(text,jsonb) to authenticated;
