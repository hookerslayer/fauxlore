-- Нейтральные силы администратора: формирования и гарнизоны без государства.
--
-- Владение выражается `state_id is null`. Такие формирования и гарнизоны не
-- попадают в списки государств, не платят содержание из чьей-либо казны и не
-- участвуют в автоматических расчётах: ими распоряжается только администратор.
-- Это согласуется с правилом проекта — исходы боёв и осад судит администратор,
-- автоматические калькуляторы сражений не используются.
--
-- Нейтральный гарнизон можно поставить только в провинции с нейтральным
-- маркером (форт, порт или город, созданный администратором), и только если
-- провинцию не занял гарнизон государства.

alter table fauxlore.military_formations alter column state_id drop not null;
alter table fauxlore.garrison_sites alter column state_id drop not null;

create or replace function fauxlore.neutral_forces_api(action text, payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; formation_row fauxlore.military_formations; unit_row fauxlore.military_unit_catalog;
  formation_key bigint; province_key integer; unit_key bigint; quantity_value integer; capacity_value integer;
  used_value integer; province_row fauxlore.provinces; site_state integer; has_site boolean;
begin
  actor:=fauxlore.current_account();
  if actor.id is null then raise sqlstate '42501' using message='Требуется вход'; end if;
  if actor.role<>'admin' then raise sqlstate '42501' using message='Доступно только администратору'; end if;

  if action='snapshot' then
    return jsonb_build_object(
      'formations',coalesce((
        select jsonb_agg(to_jsonb(f)||jsonb_build_object(
          'province_name',(select p.name from fauxlore.provinces p where p.id=f.province_id),
          'units',coalesce((
          select jsonb_agg(jsonb_build_object('unit_id',fu.unit_id,'name',u.name,'quantity',fu.quantity) order by u.name)
          from fauxlore.military_formation_units fu
          join fauxlore.military_unit_catalog u on u.id=fu.unit_id
          where fu.formation_id=f.id),'[]'::jsonb)) order by f.id)
        from fauxlore.military_formations f where f.state_id is null and f.active),'[]'::jsonb),
      'provinces',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',p.id,'name',p.name,'kind',p.kind,'province_type',p.province_type,
          'markers',(select coalesce(jsonb_agg(m.type order by m.id),'[]'::jsonb)
            from fauxlore.map_markers m where m.province_id=p.id and m.state_id is null),
          'garrison',coalesce((select jsonb_agg(jsonb_build_object('unit_id',gu.unit_id,'name',c.name,'quantity',gu.quantity) order by c.name)
            from fauxlore.garrison_units gu join fauxlore.military_unit_catalog c on c.id=gu.unit_id
            where gu.province_id=p.id and exists(select 1 from fauxlore.garrison_sites g
              where g.province_id=p.id and g.state_id is null)),'[]'::jsonb),
          'capacity',fauxlore.garrison_capacity(p.id)) order by p.name)
        from fauxlore.provinces p
        where exists(select 1 from fauxlore.map_markers m where m.province_id=p.id and m.state_id is null)),'[]'::jsonb),
      'catalog',coalesce((select jsonb_agg(to_jsonb(u) order by u.domain,u.id)
        from fauxlore.military_unit_catalog u where u.active and u.domain in ('land','siege')),'[]'::jsonb)
    );
  end if;

  if action='create_formation' then
    if length(btrim(coalesce(payload->>'name',''))) not between 2 and 100 then
      raise sqlstate '22023' using message='Название должно содержать от 2 до 100 символов'; end if;
    if coalesce(payload->>'domain','') not in ('land','naval') then
      raise sqlstate '22023' using message='Выберите тип формирования'; end if;
    province_key:=(payload->>'province_id')::integer;
    select * into province_row from fauxlore.provinces where id=province_key;
    if not found then raise sqlstate '22023' using message='Провинция не найдена'; end if;
    if payload->>'domain'='naval' then
      if province_row.kind<>'sea' or not exists(select 1 from fauxlore.map_markers m
          where m.province_id=province_key and m.type='port' and m.state_id is null) then
        raise sqlstate '22023' using message='Нейтральную флотилию можно создать только в нейтральном порту'; end if;
    elsif province_row.kind<>'land' then
      raise sqlstate '22023' using message='Нейтральная армия создаётся только в сухопутной провинции';
    elsif not exists(select 1 from fauxlore.map_markers m
        where m.province_id=province_key and m.state_id is null) then
      raise sqlstate '22023' using message='Сначала поставьте в провинции нейтральный маркер'; end if;
    insert into fauxlore.military_formations(state_id,name,domain,province_id)
      values(null,btrim(payload->>'name'),payload->>'domain',province_key) returning id into formation_key;
    return jsonb_build_object('formation_id',formation_key,'name',btrim(payload->>'name'));
  end if;

  if action='hire_unit' then
    formation_key:=(payload->>'formation_id')::bigint;
    select * into formation_row from fauxlore.military_formations
      where id=formation_key and state_id is null and active for update;
    if not found then raise sqlstate 'P0002' using message='Нейтральное формирование не найдено'; end if;
    quantity_value:=coalesce((payload->>'quantity')::integer,0);
    if quantity_value<1 or quantity_value>100000 then
      raise sqlstate '22023' using message='Укажите количество от 1 до 100 000'; end if;
    select * into unit_row from fauxlore.military_unit_catalog
      where id=(payload->>'unit_id')::bigint and active;
    if not found then raise sqlstate '22023' using message='Юнит не найден'; end if;
    if (unit_row.domain='naval')<>(formation_row.domain='naval') then
      raise sqlstate '22023' using message='Юнит не подходит этому формированию'; end if;
    insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
      values(formation_key,unit_row.id,quantity_value)
      on conflict(formation_id,unit_id) do update set quantity=fauxlore.military_formation_units.quantity+excluded.quantity;
    return jsonb_build_object('formation_id',formation_key,'unit_id',unit_row.id,'quantity',quantity_value);
  end if;

  if action='delete_formation' then
    return fauxlore.military_delete_formation(null,payload);
  end if;

  if action='garrison_add' then
    province_key:=(payload->>'province_id')::integer;
    select * into province_row from fauxlore.provinces where id=province_key and kind='land';
    if not found then raise sqlstate '22023' using message='Выберите сухопутную провинцию'; end if;
    if not exists(select 1 from fauxlore.map_markers m where m.province_id=province_key and m.state_id is null) then
      raise sqlstate '22023' using message='В провинции нет нейтрального маркера'; end if;
    select state_id into site_state from fauxlore.garrison_sites where province_id=province_key;
    if site_state is not null then
      raise sqlstate '22023' using message='Провинция занята гарнизоном государства'; end if;
    if not found then
      insert into fauxlore.garrison_sites(province_id,state_id) values(province_key,null);
    end if;
    quantity_value:=coalesce((payload->>'quantity')::integer,0);
    if quantity_value<1 or quantity_value>100000 then
      raise sqlstate '22023' using message='Укажите количество от 1 до 100 000'; end if;
    select * into unit_row from fauxlore.military_unit_catalog
      where id=(payload->>'unit_id')::bigint and active and domain in ('land','siege');
    if not found then raise sqlstate '22023' using message='Этот юнит нельзя поставить в гарнизон'; end if;
    select coalesce(sum(u.quantity*c.recruit_cost),0) into used_value from fauxlore.garrison_units u
      join fauxlore.military_unit_catalog c on c.id=u.unit_id where u.province_id=province_key;
    capacity_value:=coalesce(fauxlore.garrison_capacity(province_key),0);
    if used_value+quantity_value*unit_row.recruit_cost>capacity_value then
      raise sqlstate '22023' using message='Превышен лимит гарнизона провинции'; end if;
    insert into fauxlore.garrison_units(province_id,unit_id,quantity)
      values(province_key,unit_row.id,quantity_value)
      on conflict(province_id,unit_id) do update set quantity=fauxlore.garrison_units.quantity+excluded.quantity;
    return jsonb_build_object('province_id',province_key,'unit_id',unit_row.id,'quantity',quantity_value);
  end if;

  if action='garrison_remove' then
    province_key:=(payload->>'province_id')::integer;
    unit_key:=(payload->>'unit_id')::bigint;
    delete from fauxlore.garrison_units u
      where u.province_id=province_key and u.unit_id=unit_key
        and exists(select 1 from fauxlore.garrison_sites g where g.province_id=u.province_id and g.state_id is null);
    if not found then raise sqlstate 'P0002' using message='В нейтральном гарнизоне нет такого юнита'; end if;
    delete from fauxlore.garrison_sites g
      where g.province_id=province_key and g.state_id is null
        and not exists(select 1 from fauxlore.garrison_units u where u.province_id=g.province_id);
    return jsonb_build_object('province_id',province_key,'unit_id',unit_key,'removed',true);
  end if;

  raise sqlstate '22023' using message='Неизвестное действие нейтральных сил';
end
$function$;
revoke all on function fauxlore.neutral_forces_api(text,jsonb) from public,anon,authenticated;
grant execute on function fauxlore.neutral_forces_api(text,jsonb) to authenticated;
