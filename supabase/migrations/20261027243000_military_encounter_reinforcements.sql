-- Add later arrivals to an encounter that is already awaiting the judge.
create or replace function fauxlore.resolve_military_encounters(year_value integer,turn_value integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare candidate record; battle_id bigint; participants_value jsonb; existing_participants jsonb; state_ids integer[]; province_name text;
  state_name text; message_value text; created_count integer:=0; extend_battle boolean;
begin
  for candidate in
    select f.province_id,f.domain
    from fauxlore.military_formations f
    where f.active and f.domain in ('land','naval') and exists(
      select 1 from fauxlore.military_formations enemy
      join fauxlore.military_wars w on w.active and
        ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or
         (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))
      where enemy.active and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id)
    group by f.province_id,f.domain
    order by f.province_id,f.domain
  loop
    battle_id:=null;
    insert into fauxlore.military_battles(province_id,domain,year,turn)
      values(candidate.province_id,candidate.domain,year_value,turn_value)
      on conflict(province_id,domain,year,turn) do nothing
      returning id into battle_id;
    extend_battle:=battle_id is null;
    if extend_battle then
      select b.id,b.participants into battle_id,existing_participants from fauxlore.military_battles b
        where b.province_id=candidate.province_id and b.domain=candidate.domain
          and b.year=year_value and b.turn=turn_value and b.status='pending';
      if not found then continue; end if;
    else
      existing_participants:='[]'::jsonb;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
        'formation_id',f.id,'state_id',f.state_id,'state_name',coalesce(state_category.name,'Государство'),
        'formation_name',f.name,'domain',f.domain,'province_id',f.province_id,
        'position_x',f.position_x,'position_y',f.position_y,
        'units',(select coalesce(jsonb_agg(jsonb_build_object('unit_id',fu.unit_id,'name',u.name,'quantity',fu.quantity)
          order by fu.unit_id),'[]'::jsonb)
          from fauxlore.military_formation_units fu join fauxlore.military_unit_catalog u on u.id=fu.unit_id
          where fu.formation_id=f.id)
      ) order by f.state_id,f.id),'[]'::jsonb),
      coalesce(array_agg(distinct f.state_id order by f.state_id),'{}'::integer[])
    into participants_value,state_ids
    from fauxlore.military_formations f
    left join fauxlore.map_categories state_category on state_category.layer='states' and state_category.id=f.state_id
    where f.active and f.domain=candidate.domain and f.province_id=candidate.province_id
      and not existing_participants @> jsonb_build_array(jsonb_build_object('formation_id',f.id))
      and exists(select 1 from fauxlore.military_formations enemy join fauxlore.military_wars w on w.active and
          ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or
           (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))
        where enemy.active and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id);

    if participants_value='[]'::jsonb then continue; end if;
    update fauxlore.military_battles set participants=case when extend_battle then participants||participants_value else participants_value end
      where id=battle_id;
    delete from fauxlore.military_movement_orders mo
      where participants_value @> jsonb_build_array(jsonb_build_object('formation_id',mo.formation_id));
    select p.name into province_name from fauxlore.provinces p where p.id=candidate.province_id;
    state_name:=case candidate.domain when 'naval' then 'морское столкновение' else 'сухопутное сражение' end;
    message_value:=format('В провинции «%s» автоматически началось %s. Формирования остановлены до решения судьи.',province_name,state_name);
    insert into fauxlore.notifications(account_id,kind,title,message)
      select distinct ast.account_id,'military_battle','Началось сражение',message_value
      from fauxlore.account_states ast where ast.state_id=any(state_ids);
    created_count:=created_count+1;
  end loop;
  return created_count;
end
$function$;
revoke all on function fauxlore.resolve_military_encounters(integer,integer) from public,anon,authenticated;
