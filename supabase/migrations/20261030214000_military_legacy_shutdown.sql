insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text)
select 'military','Военное дело','army_movement_limit','Лимит передвижения армии',0,'провинции','Государство',''
where not exists(select 1 from fauxlore.permanent_modifier_definitions where source_kind='military' and modifier_key='army_movement_limit');
insert into fauxlore.permanent_modifier_definitions(source_kind,source_key,modifier_key,effect,value,unit,scope,condition_text)
select 'military','Военное дело','fleet_movement_limit','Лимит передвижения флота',0,'провинции','Государство',''
where not exists(select 1 from fauxlore.permanent_modifier_definitions where source_kind='military' and modifier_key='fleet_movement_limit');

-- Retired client RPCs must not remain callable after their UI has been removed.
revoke execute on function public.military_movement_api(text,bigint,jsonb) from authenticated,anon,public;
revoke execute on function public.military_battle_api(bigint,jsonb) from authenticated,anon,public;
revoke execute on function public.military_siege_api(integer) from authenticated,anon,public;
revoke execute on function public.military_siege_storm_api(integer,text) from authenticated,anon,public;
revoke execute on function public.naval_battle_source_api(bigint) from authenticated,anon,public;

-- No old coordinate order is allowed to resume on a later turn.
delete from fauxlore.military_movement_orders;

create or replace function public.military_split_api(formation_key bigint,payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; source_row fauxlore.military_formations; target_key bigint;
  unit_row record; amount integer; current_amount integer; count_units integer:=0;
begin
  actor:=fauxlore.current_account();
  select * into source_row from fauxlore.military_formations where id=formation_key and active for update;
  if not found then raise sqlstate '22023' using message='Формирование не найдено'; end if;
  if actor.role<>'admin' and not exists(select 1 from fauxlore.account_states s where s.account_id=actor.id and s.state_id=source_row.state_id) then
    raise sqlstate '42501' using message='Нет доступа к формированию'; end if;
  if jsonb_typeof(payload->'units')<>'array' or jsonb_array_length(payload->'units')=0 then
    raise sqlstate '22023' using message='Укажите части для отделения'; end if;
  insert into fauxlore.military_formations(state_id,name,domain,kind,province_id,position_x,position_y)
    values(source_row.state_id,coalesce(nullif(left(btrim(payload->>'name'),100),''),left(source_row.name||' — отделение',100)),
      source_row.domain,source_row.kind,source_row.province_id,source_row.position_x,source_row.position_y)
    returning id into target_key;
  for unit_row in select value from jsonb_array_elements(payload->'units') loop
    amount:=(unit_row.value->>'quantity')::integer;
    select quantity into current_amount from fauxlore.military_formation_units
      where formation_id=formation_key and unit_id=(unit_row.value->>'unit_id')::bigint for update;
    if amount<1 or current_amount is null or amount>=current_amount then
      raise sqlstate '22023' using message='Можно отделить только часть имеющихся юнитов'; end if;
    update fauxlore.military_formation_units set quantity=quantity-amount
      where formation_id=formation_key and unit_id=(unit_row.value->>'unit_id')::bigint;
    insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
      values(target_key,(unit_row.value->>'unit_id')::bigint,amount);
    count_units:=count_units+1;
  end loop;
  if count_units=0 then raise sqlstate '22023' using message='Нет юнитов для отделения'; end if;
  return jsonb_build_object('formation_id',target_key,'source_id',formation_key);
end $function$;
revoke all on function public.military_split_api(bigint,jsonb) from public,anon;
grant execute on function public.military_split_api(bigint,jsonb) to authenticated;

notify pgrst,'reload schema';

