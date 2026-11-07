-- Провинцию с нейтральным маркером нельзя колонизировать.
--
-- Нейтральный маркер — это запись `map_markers` с `state_id is null`, то есть
-- форт, порт или город, поставленный администратором в ничейной провинции.
-- Без этой проверки игрок, колонизировав провинцию, получил бы вместе с ней
-- и чужой нейтральный объект, а маркер остался бы бесхозным.
--
-- Проверка поставлена сразу после проверки нейтральности провинции и
-- действует для обоих путей колонизации — сухопутного и морского.

do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
  marker:=$m$if exists(select 1 from fauxlore.province_values v where v.province_id=target_key and v.layer='states') then raise sqlstate '22023' using message='Колонизировать можно только нейтральную провинцию'; end if;$m$;
  replacement:=marker||E'\n'||
    '  if exists(select 1 from fauxlore.map_markers m where m.province_id=target_key and m.state_id is null) then'||E'\n'||
    '    raise sqlstate ''22023'' using message=''В провинции есть нейтральный маркер: её нельзя колонизировать'';'||E'\n'||
    '  end if;';
  if position(marker in fn)=0 then
    raise exception 'Colonization neutral marker insertion point missing';
  end if;
  execute replace(fn,marker,replacement);
end
$migration$;
