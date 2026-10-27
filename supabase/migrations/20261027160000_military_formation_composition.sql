-- Split, merge and transfer composition between co-located regular armies/fleets.
create or replace function fauxlore.manage_formation_composition(action text,sid integer,payload jsonb)
returns jsonb language plpgsql set search_path='' as $function$
declare source_row fauxlore.military_formations; target_row fauxlore.military_formations;
  unit_row fauxlore.military_unit_catalog; rec jsonb; source_key bigint; target_key bigint;
  unit_key bigint; amount integer; current_amount integer; free_moved integer:=0;
  moved_total integer:=0; remaining_total bigint; created_key bigint; created_name text;
begin
 if action='split_formation' then
   source_key:=nullif(payload->>'formation_id','')::bigint;
   select * into source_row from fauxlore.military_formations
     where id=source_key and state_id=sid and active and kind='regular' for update;
   if not found then raise sqlstate '22023' using message='Армия или флотилия не найдены'; end if;
   if source_row.domain='naval' and exists(select 1 from fauxlore.colonization_missions
      where status='active' and fleet_id=source_key) then
     raise sqlstate '22023' using message='Флотилия занята колонизационной миссией'; end if;
   if jsonb_typeof(payload->'units') is distinct from 'array' or jsonb_array_length(payload->'units')=0 then
     raise sqlstate '22023' using message='Выберите части для выделения'; end if;
   if exists(select 1 from jsonb_array_elements(payload->'units') x(value)
      group by value->>'unit_id' having count(*)>1) then
     raise sqlstate '22023' using message='Один тип войск можно указать только один раз'; end if;
   created_name:=btrim(coalesce(payload->>'name',''));
   if length(created_name)<2 or length(created_name)>100 then
     raise sqlstate '22023' using message='Название нового формирования должно содержать от 2 до 100 символов'; end if;
   insert into fauxlore.military_formations(state_id,name,domain,province_id)
     values(sid,created_name,source_row.domain,source_row.province_id) returning id into created_key;
   for rec in select value from jsonb_array_elements(payload->'units') loop
     unit_key:=nullif(rec->>'unit_id','')::bigint;
     amount:=coalesce((rec->>'quantity')::integer,0);
     if amount<1 then raise sqlstate '22023' using message='Количество частей должно быть не меньше 1'; end if;
     select * into unit_row from fauxlore.military_unit_catalog where id=unit_key;
     if not found or (source_row.domain='naval' and unit_row.domain<>'naval')
        or (source_row.domain='land' and unit_row.domain not in ('land','siege')) then
       raise sqlstate '22023' using message='Тип войск не подходит этому формированию'; end if;
     select quantity into current_amount from fauxlore.military_formation_units
       where formation_id=source_key and unit_id=unit_key for update;
     if not found or amount>current_amount then
       raise sqlstate '22023' using message='В исходном формировании недостаточно выбранных частей'; end if;
     if unit_row.name='Копейщик' then
       free_moved:=free_moved+least(amount,greatest(0,source_row.free_upkeep_quantity-free_moved));
     end if;
     if amount=current_amount then
       delete from fauxlore.military_formation_units where formation_id=source_key and unit_id=unit_key;
     else
       update fauxlore.military_formation_units set quantity=quantity-amount
         where formation_id=source_key and unit_id=unit_key;
     end if;
     insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
       values(created_key,unit_key,amount);
     moved_total:=moved_total+amount;
   end loop;
   select coalesce(sum(quantity),0) into remaining_total from fauxlore.military_formation_units where formation_id=source_key;
   if remaining_total<1 then raise sqlstate '22023' using message='В исходной армии или флотилии должна остаться хотя бы одна часть'; end if;
   update fauxlore.military_formations set free_upkeep_quantity=greatest(0,free_upkeep_quantity-free_moved)
     where id=source_key;
   update fauxlore.military_formations set free_upkeep_quantity=free_moved where id=created_key;
   return jsonb_build_object('source_id',source_key,'formation_id',created_key,'name',created_name,'units_moved',moved_total);
 elsif action in ('merge_formations','transfer_units') then
   source_key:=nullif(payload->>'source_formation_id','')::bigint;
   target_key:=nullif(payload->>'target_formation_id','')::bigint;
   if source_key is null or target_key is null or source_key=target_key then
     raise sqlstate '22023' using message='Выберите два разных формирования'; end if;
   perform 1 from fauxlore.military_formations where id in (source_key,target_key)
     order by id for update;
   select * into source_row from fauxlore.military_formations
     where id=source_key and state_id=sid and active and kind='regular';
   if not found then raise sqlstate '22023' using message='Исходная армия или флотилия не найдены'; end if;
   select * into target_row from fauxlore.military_formations
     where id=target_key and state_id=sid and active and kind='regular';
   if not found then raise sqlstate '22023' using message='Целевая армия или флотилия не найдены'; end if;
   if source_row.domain<>target_row.domain then
     raise sqlstate '22023' using message='Можно объединять и пополнять только формирования одного типа'; end if;
   if source_row.province_id<>target_row.province_id then
     raise sqlstate '22023' using message='Оба формирования должны находиться в одной провинции'; end if;
   if source_row.domain='naval' and exists(select 1 from fauxlore.colonization_missions
      where status='active' and fleet_id in (source_key,target_key)) then
     raise sqlstate '22023' using message='Флотилия занята колонизационной миссией'; end if;
   if not exists(select 1 from fauxlore.military_formation_units where formation_id=source_key) then
     raise sqlstate '22023' using message='В исходном формировании нет частей'; end if;
   if action='merge_formations' then
     select coalesce(sum(quantity),0)::integer into moved_total from fauxlore.military_formation_units where formation_id=source_key;
     insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
       select target_key,unit_id,quantity from fauxlore.military_formation_units where formation_id=source_key
       on conflict(formation_id,unit_id) do update
         set quantity=fauxlore.military_formation_units.quantity+excluded.quantity;
     update fauxlore.military_formations set free_upkeep_quantity=free_upkeep_quantity+source_row.free_upkeep_quantity
       where id=target_key;
     delete from fauxlore.military_formation_units where formation_id=source_key;
     update fauxlore.military_formations set active=false,leader_id=null,free_upkeep_quantity=0 where id=source_key;
     return jsonb_build_object('source_id',source_key,'target_id',target_key,'units_moved',moved_total,'source_deactivated',true);
   end if;
   unit_key:=nullif(payload->>'unit_id','')::bigint;
   amount:=coalesce((payload->>'quantity')::integer,0);
   if amount<1 then raise sqlstate '22023' using message='Укажите количество частей не меньше 1'; end if;
   select * into unit_row from fauxlore.military_unit_catalog where id=unit_key;
   if not found or (source_row.domain='naval' and unit_row.domain<>'naval')
      or (source_row.domain='land' and unit_row.domain not in ('land','siege')) then
     raise sqlstate '22023' using message='Тип войск не подходит этому формированию'; end if;
   select quantity into current_amount from fauxlore.military_formation_units
     where formation_id=source_key and unit_id=unit_key for update;
   if not found or amount>current_amount then
     raise sqlstate '22023' using message='В исходном формировании недостаточно выбранных частей'; end if;
   if unit_row.name='Копейщик' then
     free_moved:=least(amount,source_row.free_upkeep_quantity);
   end if;
   if amount=current_amount then
     delete from fauxlore.military_formation_units where formation_id=source_key and unit_id=unit_key;
   else
     update fauxlore.military_formation_units set quantity=quantity-amount
       where formation_id=source_key and unit_id=unit_key;
   end if;
   insert into fauxlore.military_formation_units(formation_id,unit_id,quantity)
     values(target_key,unit_key,amount)
     on conflict(formation_id,unit_id) do update
       set quantity=fauxlore.military_formation_units.quantity+excluded.quantity;
   update fauxlore.military_formations set free_upkeep_quantity=greatest(0,free_upkeep_quantity-free_moved)
     where id=source_key;
   update fauxlore.military_formations set free_upkeep_quantity=free_upkeep_quantity+free_moved
     where id=target_key;
   select coalesce(sum(quantity),0) into remaining_total from fauxlore.military_formation_units where formation_id=source_key;
   if remaining_total=0 then
     update fauxlore.military_formations set active=false,leader_id=null,free_upkeep_quantity=0 where id=source_key;
   end if;
   return jsonb_build_object('source_id',source_key,'target_id',target_key,'unit_id',unit_key,
     'quantity',amount,'source_deactivated',remaining_total=0);
 end if;
 raise sqlstate '22023' using message='Неизвестное действие с составом формирования';
end
$function$;
revoke all on function fauxlore.manage_formation_composition(text,integer,jsonb) from public,anon,authenticated;

do $$ declare fn text; marker text; replacement text; begin
 fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
 marker:=' if action=''create_formation'' then';
 replacement:=' if action in (''split_formation'',''merge_formations'',''transfer_units'') then'||E'\n'||
   '  return fauxlore.manage_formation_composition(action,sid,payload);'||E'\n'||
   ' end if;'||E'\n'||marker;
 if position(marker in fn)=0 then raise exception 'Military formation action insertion point missing'; end if;
 execute replace(fn,marker,replacement);

 fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
 marker:='''create_formation'',''rename_formation''';
 replacement:='''split_formation'',''merge_formations'',''transfer_units'','||marker;
 if position(marker in fn)=0 then raise exception 'Military API action dispatch insertion point missing'; end if;
 execute replace(fn,marker,replacement);
end $$;

-- Protect the administrator's reversible test turn from silently deleting later composition changes.
create trigger military_formations_live_revision
  after insert or update or delete on fauxlore.military_formations
  for each statement execute function fauxlore.bump_live_revision();
create trigger military_formation_units_live_revision
  after insert or update or delete on fauxlore.military_formation_units
  for each statement execute function fauxlore.bump_live_revision();
notify pgrst,'reload schema';
