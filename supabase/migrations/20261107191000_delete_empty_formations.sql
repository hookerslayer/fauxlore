-- Владелец государства или администратор удаляет пустое формирование
-- (армию или флотилию), в котором не осталось юнитов.
--
-- Удаление мягкое (`active=false`), поэтому история формирований и приказов
-- сохраняется, а расчёты содержания, боя и списков перестают его видеть.
-- Формирование нельзя удалить, пока оно перевозит груз, само находится на
-- борту, имеет нерассмотренный приказ или занято колонизационной миссией.

create or replace function fauxlore.military_delete_formation(sid integer, payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $function$
declare actor fauxlore.accounts; formation_row fauxlore.military_formations;
  formation_key bigint; unit_count bigint;
begin
  actor:=fauxlore.current_account();
  if actor.id is null then raise sqlstate '42501' using message='Требуется вход'; end if;
  formation_key:=nullif(payload->>'formation_id','')::bigint;
  if formation_key is null then raise sqlstate '22023' using message='Не выбрано формирование'; end if;
  select * into formation_row from fauxlore.military_formations where id=formation_key and active for update;
  if not found then raise sqlstate 'P0002' using message='Формирование не найдено'; end if;
  if actor.role<>'admin' and not exists(
      select 1 from fauxlore.account_states a
      where a.account_id=actor.id and a.state_id=formation_row.state_id) then
    raise sqlstate '42501' using message='Нет доступа к формированию';
  end if;
  select coalesce(sum(u.quantity),0) into unit_count
    from fauxlore.military_formation_units u where u.formation_id=formation_key;
  if unit_count>0 then
    raise sqlstate '22023' using message='Удалить можно только формирование без юнитов';
  end if;
  if formation_row.transported_by is not null
     or exists(select 1 from fauxlore.military_formations f where f.transported_by=formation_key and f.active) then
    raise sqlstate '22023' using message='Формирование участвует в перевозке';
  end if;
  if exists(select 1 from fauxlore.military_orders o
      where o.formation_id=formation_key and o.status in ('pending','approved')) then
    raise sqlstate '22023' using message='Сначала отмените приказ формирования';
  end if;
  if exists(select 1 from fauxlore.colonization_missions m
      where m.fleet_id=formation_key and m.status='active') then
    raise sqlstate '22023' using message='Флотилия занята колонизационной миссией';
  end if;
  update fauxlore.military_formations
    set active=false, leader_id=null, transported_by=null
    where id=formation_key;
  return jsonb_build_object('deleted',true,'formation_id',formation_key,'name',formation_row.name);
end
$function$;
revoke all on function fauxlore.military_delete_formation(integer,jsonb) from public,anon,authenticated;

do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.military_actions_extra(text,integer,jsonb)'::regprocedure);
  marker:=' if action=''create_formation'' then';
  replacement:=' if action=''delete_formation'' then'||E'\n'||
    '  return fauxlore.military_delete_formation(sid,payload);'||E'\n'||
    ' end if;'||E'\n'||marker;
  if position(marker in fn)=0 then raise exception 'Formation delete insertion point missing'; end if;
  execute replace(fn,marker,replacement);

  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  marker:='''create_formation'',''rename_formation''';
  replacement:='''delete_formation'','||marker;
  if position(marker in fn)=0 then raise exception 'Formation delete dispatch insertion point missing'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;
