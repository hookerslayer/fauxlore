-- Массовое прочтение уведомлений: PATCH notifications/read-all.
do $guard$
begin
  if current_database() <> 'fauxlore_production_candidate' then
    raise exception 'Refusing to patch registration API outside production candidate';
  end if;
end
$guard$;

do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.registration_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker := $m$  elsif method='PATCH' and path~'^notifications/[0-9]+/read$' then$m$;
  if position(marker in definition) = 0 then
    raise exception 'Could not locate notification read branch';
  end if;
  replacement := $m$  elsif method='PATCH' and path='notifications/read-all' then
    update fauxlore.notifications set read_at=coalesce(read_at,now()) where account_id=a.id and read_at is null;
    result:=jsonb_build_object('ok',true);
$m$ || marker;
  definition := replace(definition, marker, replacement);
  execute definition;
end
$patch$;
