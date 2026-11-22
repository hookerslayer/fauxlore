-- Тестовый ход администратора больше не используется: убираем маршрут API
-- и вспомогательные объекты. Активного снимка тестового хода нет.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to remove test turn outside production candidate';
  end if;
  if exists(select 1 from fauxlore.turn_test_snapshot) then
    raise exception 'Test turn snapshot is active; roll it back before removing the feature';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text;
begin
  select pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker := $m$  elsif path='admin/turn/test' or path like 'admin/turn/test/%' then return fauxlore.test_turn_api(path,method,body,request_id);$m$;
  if position(marker in definition) = 0 then
    raise exception 'Test turn route not found';
  end if;
  definition := replace(definition, marker, '');
  execute definition;
end
$patch$;

drop function if exists fauxlore.test_turn_api(text,text,jsonb,uuid);
drop table if exists fauxlore.turn_test_snapshot;
