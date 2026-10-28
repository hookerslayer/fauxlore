-- Add administrator-only post removal to the existing Wall RPC.
do $migration$
declare definition text;
  marker text := '  if action=''create'' then';
  replacement text := '  if action=''delete'' then'||chr(10)||
    '    if actor.role<>''admin'' then raise sqlstate ''42501'' using message=''Нужна роль администратора''; end if;'||chr(10)||
    '    pid:=(payload->>''post_id'')::bigint;'||chr(10)||
    '    delete from fauxlore.wall_posts where id=pid;'||chr(10)||
    '    if not found then raise sqlstate ''P0002'' using message=''Пост не найден''; end if;'||chr(10)||
    '    return jsonb_build_object(''deleted'',true,''post_id'',pid);'||chr(10)||
    '  elsif action=''create'' then';
begin
  definition:=pg_get_functiondef('fauxlore.wall_api(text,jsonb)'::regprocedure);
  if position(marker in definition)=0 then raise exception 'Wall create action hook missing'; end if;
  execute replace(definition,marker,replacement);
end $migration$;
