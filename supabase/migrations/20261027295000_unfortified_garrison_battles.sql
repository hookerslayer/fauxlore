-- Unfortified garrisons join the existing judge-resolved land battle flow as explicit participants.
create or replace function fauxlore.resolve_military_encounters(year_value integer,turn_value integer)
returns integer language plpgsql security definer set search_path='' as $function$
declare candidate record; battle_id bigint; participants_value jsonb; existing_participants jsonb;
  state_ids integer[]; province_name text; state_name text; message_value text;
  created_count integer:=0; extend_battle boolean;
begin
  for candidate in
    select conflicts.province_id,conflicts.domain from (
      select f.province_id,f.domain
      from fauxlore.military_formations f
      where f.active and f.transported_by is null and f.domain in ('land','naval') and exists(
        select 1 from fauxlore.military_formations enemy join fauxlore.military_wars w on w.active and
          ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))
        where enemy.active and enemy.transported_by is null and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id)
      union
      select f.province_id,'land'::text
      from fauxlore.military_formations f
      join fauxlore.garrison_sites g on g.province_id=f.province_id and g.fort_level=0 and g.wall_level=0
      join fauxlore.garrison_units gu on gu.province_id=g.province_id
      join fauxlore.military_wars w on w.active and
        ((w.attacker_id=f.state_id and w.defender_id=g.state_id) or (w.defender_id=f.state_id and w.attacker_id=g.state_id))
      where f.active and f.transported_by is null and f.domain='land'
    ) conflicts order by conflicts.province_id,conflicts.domain
  loop
    battle_id:=null;
    insert into fauxlore.military_battles(province_id,domain,year,turn)
      values(candidate.province_id,candidate.domain,year_value,turn_value)
      on conflict(province_id,domain,year,turn) do nothing returning id into battle_id;
    extend_battle:=battle_id is null;
    if extend_battle then
      select b.id,b.participants into battle_id,existing_participants from fauxlore.military_battles b
        where b.province_id=candidate.province_id and b.domain=candidate.domain and b.year=year_value
          and b.turn=turn_value and b.status='pending';
      if not found then continue; end if;
    else existing_participants:='[]'::jsonb;
    end if;

    with sides as (
      select jsonb_build_object('formation_id',f.id,'state_id',f.state_id,
        'state_name',coalesce(c.name,'Государство'),'formation_name',f.name,'kind',f.kind,
        'domain',f.domain,'province_id',f.province_id,'position_x',f.position_x,'position_y',f.position_y,
        'units',(select coalesce(jsonb_agg(jsonb_build_object('unit_id',fu.unit_id,'name',u.name,'quantity',fu.quantity)
          order by fu.unit_id),'[]'::jsonb) from fauxlore.military_formation_units fu
          join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=f.id)) participant,
        f.state_id,f.id sort_id
      from fauxlore.military_formations f
      left join fauxlore.map_categories c on c.layer='states' and c.id=f.state_id
      where f.active and f.transported_by is null and f.domain=candidate.domain and f.province_id=candidate.province_id
        and not existing_participants @> jsonb_build_array(jsonb_build_object('formation_id',f.id))
        and (exists(select 1 from fauxlore.military_formations enemy join fauxlore.military_wars w on w.active and
            ((w.attacker_id=f.state_id and w.defender_id=enemy.state_id) or (w.defender_id=f.state_id and w.attacker_id=enemy.state_id))
          where enemy.active and enemy.transported_by is null and enemy.id<>f.id and enemy.domain=f.domain and enemy.province_id=f.province_id)
          or exists(select 1 from fauxlore.garrison_sites g join fauxlore.garrison_units gu on gu.province_id=g.province_id
            join fauxlore.military_wars w on w.active and
              ((w.attacker_id=f.state_id and w.defender_id=g.state_id) or (w.defender_id=f.state_id and w.attacker_id=g.state_id))
            where f.domain='land' and g.province_id=f.province_id and g.fort_level=0 and g.wall_level=0))
      union all
      select jsonb_build_object('formation_id',-g.province_id::bigint,'state_id',g.state_id,
        'state_name',coalesce(c.name,'Государство'),'formation_name','Гарнизон','kind','garrison',
        'garrison_province_id',g.province_id,'domain','land','province_id',g.province_id,
        'position_x',(p.center->>0)::double precision,'position_y',(p.center->>1)::double precision,
        'units',(select coalesce(jsonb_agg(jsonb_build_object('unit_id',gu.unit_id,'name',u.name,'quantity',gu.quantity)
          order by gu.unit_id),'[]'::jsonb) from fauxlore.garrison_units gu
          join fauxlore.military_unit_catalog u on u.id=gu.unit_id where gu.province_id=g.province_id)) participant,
        g.state_id,-g.province_id::bigint sort_id
      from fauxlore.garrison_sites g
      join fauxlore.provinces p on p.id=g.province_id
      left join fauxlore.map_categories c on c.layer='states' and c.id=g.state_id
      where candidate.domain='land' and g.province_id=candidate.province_id and g.fort_level=0 and g.wall_level=0
        and exists(select 1 from fauxlore.garrison_units gu where gu.province_id=g.province_id)
        and not existing_participants @> jsonb_build_array(jsonb_build_object('formation_id',-g.province_id::bigint))
        and exists(select 1 from fauxlore.military_formations f join fauxlore.military_wars w on w.active and
          ((w.attacker_id=f.state_id and w.defender_id=g.state_id) or (w.defender_id=f.state_id and w.attacker_id=g.state_id))
          where f.active and f.transported_by is null and f.domain='land' and f.province_id=g.province_id)
    )
    select coalesce(jsonb_agg(participant order by state_id,sort_id),'[]'::jsonb),
      coalesce(array_agg(distinct state_id order by state_id),'{}'::integer[])
    into participants_value,state_ids from sides;

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

-- Extend battle resolution so garrison losses persist in garrison_units and surrender transfers the site.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.military_battle_api(bigint,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='  passenger_row record; transported_losses jsonb:=''[]''::jsonb;';
  new_fragment:=old_fragment||chr(10)||'  garrison_mode boolean; garrison_key integer;';
  if position(old_fragment in fn)=0 then raise exception 'Garrison battle declarations marker missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  -- Replace the participant lookup and unit cursor as one bounded block.
  old_fragment:='    select * into formation_row from fauxlore.military_formations f where f.id=(participant->>''formation_id'')::bigint'||chr(10)||
    '       and f.active and f.state_id=(participant->>''state_id'')::integer and f.province_id=battle_row.province_id'||chr(10)||
    '       and f.domain=battle_row.domain;'||chr(10)||
    '    if not found then'||chr(10)||
    '      raise sqlstate ''40001'' using message=''Состав сражения изменился; обновите страницу'';'||chr(10)||
    '    end if;'||chr(10)||
    '    for unit_row in select fu.unit_id,fu.quantity,u.name from fauxlore.military_formation_units fu'||chr(10)||
    '      join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=(participant->>''formation_id'')::bigint'||chr(10)||
    '    loop';
  new_fragment:='    garrison_mode:=coalesce(participant->>''kind'',''regular'')=''garrison'';'||chr(10)||
    '    garrison_key:=coalesce((participant->>''garrison_province_id'')::integer,battle_row.province_id);'||chr(10)||
    '    if garrison_mode then'||chr(10)||
    '      perform 1 from fauxlore.garrison_sites g where g.province_id=garrison_key'||chr(10)||
    '        and g.state_id=(participant->>''state_id'')::integer and g.province_id=battle_row.province_id'||chr(10)||
    '        and g.fort_level=0 and g.wall_level=0 for update;'||chr(10)||
    '      if not found then raise sqlstate ''40001'' using message=''Состав гарнизона сражения изменился; обновите страницу''; end if;'||chr(10)||
    '    else'||chr(10)||
    '      select * into formation_row from fauxlore.military_formations f where f.id=(participant->>''formation_id'')::bigint'||chr(10)||
    '        and f.active and f.state_id=(participant->>''state_id'')::integer and f.province_id=battle_row.province_id'||chr(10)||
    '        and f.domain=battle_row.domain;'||chr(10)||
    '      if not found then raise sqlstate ''40001'' using message=''Состав сражения изменился; обновите страницу''; end if;'||chr(10)||
    '    end if;'||chr(10)||
    '    for unit_row in select fu.unit_id,fu.quantity,u.name from fauxlore.military_formation_units fu'||chr(10)||
    '      join fauxlore.military_unit_catalog u on u.id=fu.unit_id where not garrison_mode and fu.formation_id=(participant->>''formation_id'')::bigint'||chr(10)||
    '      union all select gu.unit_id,gu.quantity,u.name from fauxlore.garrison_units gu'||chr(10)||
    '        join fauxlore.military_unit_catalog u on u.id=gu.unit_id where garrison_mode and gu.province_id=garrison_key'||chr(10)||
    '    loop';
  if position(old_fragment in fn)=0 then raise exception 'Garrison participant cursor marker missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='if loss_value>0 then'||chr(10)||
    '        if loss_value=unit_row.quantity then'||chr(10)||
    '          delete from fauxlore.military_formation_units where formation_id=(participant->>''formation_id'')::bigint and unit_id=unit_row.unit_id;'||chr(10)||
    '        else'||chr(10)||
    '          update fauxlore.military_formation_units set quantity=quantity-loss_value'||chr(10)||
    '            where formation_id=(participant->>''formation_id'')::bigint and unit_id=unit_row.unit_id;'||chr(10)||
    '        end if;'||chr(10)||
    '      end if;';
  new_fragment:='if loss_value>0 then'||chr(10)||
    '        if garrison_mode then'||chr(10)||
    '          if loss_value=unit_row.quantity then delete from fauxlore.garrison_units where province_id=garrison_key and unit_id=unit_row.unit_id;'||chr(10)||
    '          else update fauxlore.garrison_units set quantity=quantity-loss_value where province_id=garrison_key and unit_id=unit_row.unit_id; end if;'||chr(10)||
    '        elsif loss_value=unit_row.quantity then'||chr(10)||
    '          delete from fauxlore.military_formation_units where formation_id=(participant->>''formation_id'')::bigint and unit_id=unit_row.unit_id;'||chr(10)||
    '        else'||chr(10)||
    '          update fauxlore.military_formation_units set quantity=quantity-loss_value'||chr(10)||
    '            where formation_id=(participant->>''formation_id'')::bigint and unit_id=unit_row.unit_id;'||chr(10)||
    '        end if;'||chr(10)||
    '      end if;';
  if position(old_fragment in fn)=0 then raise exception 'Garrison loss application marker missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='    if (participant->>''state_id'')::integer<>winner_key then'||chr(10)||
    '      retreat_key:=';
  new_fragment:='    if (participant->>''state_id'')::integer<>winner_key and not garrison_mode then'||chr(10)||
    '      retreat_key:=';
  if position(old_fragment in fn)=0 then raise exception 'Garrison retreat exclusion marker missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='  if battle_row.domain=''land'' then'||chr(10)||
    '    select category_id into province_owner';
  new_fragment:='  if battle_row.domain=''land'' then'||chr(10)||
    '    update fauxlore.garrison_sites g set state_id=winner_key'||chr(10)||
    '      where g.province_id=battle_row.province_id and exists(select 1 from jsonb_array_elements(battle_row.participants) p'||chr(10)||
    '        where p->>''kind''=''garrison'' and (p->>''state_id'')::integer<>winner_key);'||chr(10)||
    '    delete from fauxlore.garrison_units gu where gu.province_id=battle_row.province_id'||chr(10)||
    '      and exists(select 1 from jsonb_array_elements(battle_row.participants) p where p->>''kind''=''garrison'''||chr(10)||
    '        and (p->>''state_id'')::integer<>winner_key);'||chr(10)||
    '    select category_id into province_owner';
  if position(old_fragment in fn)=0 then raise exception 'Garrison surrender marker missing'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  execute fn;
end
$migration$;

select pg_notify('pgrst','reload schema');
