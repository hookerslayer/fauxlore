-- «Не выше Невмешательства» должно запрещать Признание (и Официальную),
-- но не Ассимиляцию и Истребление. «Не ниже Невмешательства» — наоборот.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch religion status limits outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text;
begin
  select pg_get_functiondef('fauxlore.group_status_api(text,text,jsonb,uuid)'::regprocedure) into definition;

  marker := $m$    if status_value in ('Ассимиляция','Истребление') and exists(
      select 1 from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) m where m->>'key'='religion_status_max') then
      raise sqlstate '22023' using message='Официальная религия запрещает устанавливать статус выше «Невмешательство»';
    end if;$m$;
  if position(marker in definition) = 0 then raise exception 'religion_status_max block changed'; end if;
  definition := replace(definition, marker,
    $m$    if status_value='Признание' and exists(
      select 1 from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) m where m->>'key'='religion_status_max') then
      raise sqlstate '22023' using message='Официальная религия запрещает устанавливать статус выше «Невмешательство»';
    end if;$m$);

  marker := $m$    if status_value='Признание' and exists(
      select 1 from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) m where m->>'key'='religion_status_min') then
      raise sqlstate '22023' using message='Официальная религия запрещает устанавливать статус ниже «Невмешательство»';
    end if;$m$;
  if position(marker in definition) = 0 then raise exception 'religion_status_min block changed'; end if;
  definition := replace(definition, marker,
    $m$    if status_value in ('Ассимиляция','Истребление') and exists(
      select 1 from jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) m where m->>'key'='religion_status_min') then
      raise sqlstate '22023' using message='Официальная религия запрещает устанавливать статус ниже «Невмешательство»';
    end if;$m$);

  execute definition;
end
$patch$;
