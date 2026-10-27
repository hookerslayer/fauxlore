-- Judge resolves an automatically created battle: winner, unit losses, retreat and land control.
create or replace function public.military_battle_api(battle_key bigint,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; battle_row fauxlore.military_battles; formation_row fauxlore.military_formations; winner_key integer;
  winner_name text; participant jsonb; unit_row record; loss_value integer; retreat_key integer;
  retreat_row fauxlore.provinces; adjacent boolean;
  losses_value jsonb:='[]'::jsonb; retreats_value jsonb:='[]'::jsonb; state_ids integer[];
  province_owner integer; province_name text; notification_text text;
begin
  actor:=fauxlore.current_account();
  if actor.role<>'admin' then raise sqlstate '42501' using message='Решать сражения может только администратор'; end if;
  select * into battle_row from fauxlore.military_battles where id=battle_key for update;
  if not found or battle_row.status<>'pending' then raise sqlstate '22023' using message='Сражение уже завершено или не найдено'; end if;
  winner_key:=(payload->>'winner_state_id')::integer;
  if not exists(select 1 from jsonb_array_elements(battle_row.participants) p where (p->>'state_id')::integer=winner_key) then
    raise sqlstate '22023' using message='Выберите победившее государство из участников сражения';
  end if;
  select name into winner_name from fauxlore.map_categories where layer='states' and id=winner_key;
  if winner_name is null then raise sqlstate '22023' using message='Государство-победитель не найдено'; end if;
  select coalesce(array_agg(distinct (p->>'state_id')::integer),'{}'::integer[]) into state_ids
    from jsonb_array_elements(battle_row.participants) p;
  select name into province_name from fauxlore.provinces where id=battle_row.province_id;

  -- Resolve losses against current unit counts, rejecting stale or fabricated entries.
  for participant in select value from jsonb_array_elements(battle_row.participants) loop
    select * into formation_row from fauxlore.military_formations f where f.id=(participant->>'formation_id')::bigint
       and f.active and f.state_id=(participant->>'state_id')::integer and f.province_id=battle_row.province_id
       and f.domain=battle_row.domain;
    if not found then
      raise sqlstate '40001' using message='Состав сражения изменился; обновите страницу';
    end if;
    for unit_row in select fu.unit_id,fu.quantity,u.name from fauxlore.military_formation_units fu
      join fauxlore.military_unit_catalog u on u.id=fu.unit_id where fu.formation_id=(participant->>'formation_id')::bigint
    loop
      loss_value:=0;
      select coalesce((x->>'losses')::integer,0) into loss_value
        from jsonb_array_elements(coalesce(payload->'losses','[]'::jsonb)) x
        where (x->>'formation_id')::bigint=(participant->>'formation_id')::bigint
          and (x->>'unit_id')::bigint=unit_row.unit_id limit 1;
      loss_value:=coalesce(loss_value,0);
      if loss_value<0 or loss_value>unit_row.quantity then raise sqlstate '22023' using message='Потери должны быть от 0 до текущего числа частей'; end if;
      if loss_value>0 then
        if loss_value=unit_row.quantity then
          delete from fauxlore.military_formation_units where formation_id=(participant->>'formation_id')::bigint and unit_id=unit_row.unit_id;
        else
          update fauxlore.military_formation_units set quantity=quantity-loss_value
            where formation_id=(participant->>'formation_id')::bigint and unit_id=unit_row.unit_id;
        end if;
      end if;
      losses_value:=losses_value||jsonb_build_array(jsonb_build_object('formation_id',(participant->>'formation_id')::bigint,
        'formation_name',participant->>'formation_name','state_id',(participant->>'state_id')::integer,
        'unit_id',unit_row.unit_id,'unit_name',unit_row.name,'losses',loss_value));
    end loop;
    if (participant->>'state_id')::integer<>winner_key then
      retreat_key:=(select (x->>'province_id')::integer from jsonb_array_elements(coalesce(payload->'retreats','[]'::jsonb)) x
        where (x->>'formation_id')::bigint=(participant->>'formation_id')::bigint limit 1);
      if retreat_key is null then raise sqlstate '22023' using message='Для каждого проигравшего формирования укажите провинцию отхода'; end if;
      select * into retreat_row from fauxlore.provinces where id=retreat_key;
      if not found then
        raise sqlstate '22023' using message='Провинция отхода не найдена';
      end if;
      if (battle_row.domain='naval' and retreat_row.kind<>'sea') or (battle_row.domain='land' and retreat_row.kind<>'land') then
        raise sqlstate '22023' using message='Провинция отхода имеет неподходящий тип';
      end if;
      select exists(select 1 from fauxlore.map_adjacency a
        join lateral jsonb_array_elements_text(a.neighbors->battle_row.province_id::text) n(value) on true
        where a.singleton and n.value::integer=retreat_key) into adjacent;
      if not adjacent or fauxlore.military_province_mask_id((retreat_row.center->>0)::double precision,(retreat_row.center->>1)::double precision)<>retreat_row.id then
        raise sqlstate '22023' using message='Отход возможен только в соседнюю корректную провинцию';
      end if;
      if battle_row.domain='land' and exists(select 1 from fauxlore.provinces p
        left join fauxlore.province_values owner on owner.province_id=p.id and owner.layer='states'
        left join fauxlore.map_categories occupier on occupier.layer='states' and lower(occupier.name)=lower(p.occupation)
        where p.id=retreat_key and coalesce(occupier.id,owner.category_id) is not null
          and coalesce(occupier.id,owner.category_id)<>(participant->>'state_id')::integer) then
        raise sqlstate '22023' using message='Сухопутное формирование может отойти только в свою или нейтральную провинцию';
      end if;
      update fauxlore.military_formations set province_id=retreat_row.id,
        position_x=(retreat_row.center->>0)::double precision,position_y=(retreat_row.center->>1)::double precision
        where id=(participant->>'formation_id')::bigint;
      delete from fauxlore.military_movement_orders where formation_id=(participant->>'formation_id')::bigint;
      retreats_value:=retreats_value||jsonb_build_array(jsonb_build_object('formation_id',(participant->>'formation_id')::bigint,
        'formation_name',participant->>'formation_name','state_id',(participant->>'state_id')::integer,
        'province_id',retreat_row.id,'province_name',retreat_row.name));
    end if;
  end loop;

  if battle_row.domain='land' then
    select category_id into province_owner from fauxlore.province_values where province_id=battle_row.province_id and layer='states';
    update fauxlore.provinces set occupation=case when province_owner=winner_key then null else winner_name end,control=100
      where id=battle_row.province_id;
  end if;
  update fauxlore.military_battles set status='resolved',winner_state_id=winner_key,
    result=jsonb_build_object('winner_state_id',winner_key,'winner_name',winner_name,'losses',losses_value,'retreats',retreats_value,
      'control_transferred',battle_row.domain='land','province_id',battle_row.province_id),resolved_at=now() where id=battle_row.id;
  notification_text:=format('%s в провинции «%s» завершилось. Победитель: %s. Потери и отход внесены судьёй.%s',
    case battle_row.domain when 'naval' then 'Морское столкновение' else 'Сражение' end,province_name,winner_name,
    case when battle_row.domain='land' then ' Контроль провинции перешёл победителю.' else '' end);
  insert into fauxlore.notifications(account_id,kind,title,message)
    select distinct ast.account_id,'military_battle','Решение по сражению',notification_text
    from fauxlore.account_states ast where ast.state_id=any(state_ids);
  return jsonb_build_object('ok',true,'battle_id',battle_row.id,'winner_state_id',winner_key,
    'losses',losses_value,'retreats',retreats_value,'control_transferred',battle_row.domain='land');
end;
$function$;
revoke all on function public.military_battle_api(bigint,jsonb) from public,anon;
grant execute on function public.military_battle_api(bigint,jsonb) to authenticated;

-- The judge receives only valid, adjacent province centers as retreat destinations.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='''battles'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',b.id,''province_id'',b.province_id,''province_name'',p.name,''domain'',b.domain,''year'',b.year,''turn'',b.turn,''participants'',b.participants) order by b.created_at),''[]''::jsonb)';
  new_fragment:='''battles'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',b.id,''province_id'',b.province_id,''province_name'',p.name,''domain'',b.domain,''year'',b.year,''turn'',b.turn,''participants'',b.participants,'||
    '''retreat_options'',(select coalesce(jsonb_agg(jsonb_build_object(''id'',d.id,''name'',d.name) order by d.name),''[]''::jsonb) from fauxlore.map_adjacency adj join lateral jsonb_array_elements_text(adj.neighbors->b.province_id::text) neighbor(value) on true join fauxlore.provinces d on d.id=neighbor.value::integer where adj.singleton and d.kind=case when b.domain=''naval'' then ''sea'' else ''land'' end and fauxlore.military_province_mask_id((d.center->>0)::double precision,(d.center->>1)::double precision)=d.id)) order by b.created_at),''[]''::jsonb)';
  if position(old_fragment in fn)=0 then raise exception 'Could not add judge retreat options to military snapshot'; end if;
  execute replace(fn,old_fragment,new_fragment);
end;
$migration$;
select pg_notify('pgrst','reload schema');
