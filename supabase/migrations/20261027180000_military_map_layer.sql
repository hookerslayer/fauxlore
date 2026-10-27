-- Expose only military formations visible under the army.md fog-of-war rules.
create or replace function public.military_map_api()
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
  actor fauxlore.accounts;
  actor_states integer[];
  visible_provinces integer[];
  neighbors jsonb;
  all_visible boolean;
begin
  actor:=fauxlore.current_account();
  all_visible:=actor.role='admin';
  select coalesce(array_agg(state_id order by state_id),'{}'::integer[]) into actor_states
    from fauxlore.account_states where account_id=actor.id;
  if all_visible then
    visible_provinces:=null;
  else
    select coalesce(array_agg(distinct visible.province_id),'{}'::integer[]) into visible_provinces
    from (
      select pv.province_id
      from fauxlore.province_values pv
      where pv.layer='states' and pv.category_id=any(actor_states)
      union
      select neighbor.value::integer
      from fauxlore.province_values pv
      cross join fauxlore.map_adjacency graph
      cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->pv.province_id::text,'[]'::jsonb)) neighbor(value)
      where pv.layer='states' and pv.category_id=any(actor_states)
      union
      select f.province_id
      from fauxlore.military_formations f
      where f.active and f.state_id=any(actor_states)
      union
      select neighbor.value::integer
      from fauxlore.military_formations f
      cross join fauxlore.map_adjacency graph
      cross join lateral jsonb_array_elements_text(coalesce(graph.neighbors->f.province_id::text,'[]'::jsonb)) neighbor(value)
      where f.active and f.state_id=any(actor_states)
    ) visible;
  end if;
  return jsonb_build_object(
    'formations',(select coalesce(jsonb_agg(jsonb_build_object(
       'id',f.id,'name',f.name,'domain',f.domain,'kind',f.kind,'province_id',f.province_id,
       'province_name',p.name,'x',(p.center->>0)::numeric,'y',(p.center->>1)::numeric,
       'state_id',f.state_id,'state_name',state.name,'state_color',state.color,
       'leader_name',leader.name,'units',coalesce((select jsonb_agg(jsonb_build_object('unit_id',u.id,'name',u.name,'quantity',fu.quantity) order by u.name)
          from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
          where fu.formation_id=f.id),'[]'::jsonb),
       'total_quantity',coalesce((select sum(fu.quantity) from fauxlore.military_formation_units fu where fu.formation_id=f.id),0)
     ) order by f.province_id,f.id),'[]'::jsonb)
     from fauxlore.military_formations f
     join fauxlore.provinces p on p.id=f.province_id
     join fauxlore.map_categories state on state.layer='states' and state.id=f.state_id
     left join fauxlore.military_leaders leader on leader.id=f.leader_id
     where f.active and (all_visible or f.state_id=any(actor_states) or f.province_id=any(visible_provinces))
    ),
    'garrisons',(select coalesce(jsonb_agg(jsonb_build_object(
       'token_type','garrison','province_id',g.province_id,'province_name',p.name,
       'x',(p.center->>0)::numeric,'y',(p.center->>1)::numeric,
       'state_id',g.state_id,'state_name',state.name,'state_color',state.color,
       'fort_level',g.fort_level,'wall_level',g.wall_level,
       'units',coalesce((select jsonb_agg(jsonb_build_object('unit_id',u.id,'name',u.name,'quantity',gu.quantity) order by u.name)
          from fauxlore.garrison_units gu join fauxlore.military_unit_catalog u on u.id=gu.unit_id
          where gu.province_id=g.province_id),'[]'::jsonb),
       'total_quantity',coalesce((select sum(gu.quantity) from fauxlore.garrison_units gu where gu.province_id=g.province_id),0)
     ) order by g.province_id),'[]'::jsonb)
     from fauxlore.garrison_sites g
     join fauxlore.provinces p on p.id=g.province_id
     join fauxlore.map_categories state on state.layer='states' and state.id=g.state_id
     where (all_visible or g.state_id=any(actor_states) or g.province_id=any(visible_provinces))
       and exists(select 1 from fauxlore.garrison_units gu where gu.province_id=g.province_id)
    ),
    'fog_of_war',not all_visible
  );
end
$function$;
revoke all on function public.military_map_api() from public,anon;
grant execute on function public.military_map_api() to authenticated;
notify pgrst,'reload schema';
