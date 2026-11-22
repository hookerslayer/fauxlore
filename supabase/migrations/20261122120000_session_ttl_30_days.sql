-- Сессия должна переживать обновление страницы и длительные перерывы.
-- Раньше renew_session принимал не более 12 часов, а cookie жила 12 часов.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch session lifetime outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text;
begin
  select pg_get_functiondef('fauxlore_vps_preview.renew_session(bytea,integer)'::regprocedure) into definition;
  marker := $m$IF idle_seconds < 1 OR idle_seconds > 43200 THEN RETURN false; END IF;$m$;
  if position(marker in definition) = 0 then
    raise exception 'Session lifetime check not found';
  end if;
  definition := replace(definition, marker,
    $m$IF idle_seconds < 1 OR idle_seconds > 2592000 THEN RETURN false; END IF;$m$);
  execute definition;
end
$patch$;
