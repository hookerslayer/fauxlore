create table fauxlore.wall_settings (
  singleton boolean primary key default true check (singleton),
  player_posting_enabled boolean not null default true
);
insert into fauxlore.wall_settings(singleton) values (true);
alter table fauxlore.wall_settings enable row level security;
revoke all on fauxlore.wall_settings from public, anon, authenticated;

do $migration$
declare
  definition text;
  list_marker text := '  if action=''filters'' then';
  create_marker text := '  elsif action=''create'' then';
  settings_action text := $snippet$  if action='settings' then
    return (select jsonb_build_object('player_posting_enabled', player_posting_enabled) from fauxlore.wall_settings where singleton);
  end if;
  if action='set_posting' then
    if actor.id is null or actor.role<>'admin' then raise sqlstate '42501' using message='Нужна роль администратора'; end if;
    if jsonb_typeof(payload->'enabled') is distinct from 'boolean' then raise sqlstate '22023' using message='Укажите состояние публикации'; end if;
    update fauxlore.wall_settings set player_posting_enabled=(payload->>'enabled')::boolean where singleton;
    return (select jsonb_build_object('player_posting_enabled', player_posting_enabled) from fauxlore.wall_settings where singleton);
  end if;
$snippet$;
  create_check text := $snippet$  elsif action='create' then
    if actor.role<>'admin' and not (select player_posting_enabled from fauxlore.wall_settings where singleton for share) then
      raise sqlstate '42501' using message='Сейчас выкладывание постов выключено, ожидайте нового хода!';
    end if;$snippet$;
begin
  definition := pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  if position(list_marker in definition)=0 or position(create_marker in definition)=0 then raise exception 'Wall API hooks missing'; end if;
  definition := replace(definition,list_marker,settings_action||list_marker);
  definition := replace(definition,create_marker,create_check);
  execute definition;
end $migration$;
notify pgrst,'reload schema';
