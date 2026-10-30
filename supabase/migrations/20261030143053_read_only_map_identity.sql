-- Opening the public map must not create/link accounts or reject a new session.
do $migration$
declare definition text; old_line text; new_line text;
begin
  definition:=pg_get_functiondef('fauxlore.map_payload()'::regprocedure);
  old_line:='    account_row := fauxlore.current_account();';
  new_line:='    select * into account_row from fauxlore.accounts where auth_user_id=auth.uid();';
  if position(old_line in definition)=0 then raise exception 'Map identity lookup changed'; end if;
  execute replace(definition,old_line,new_line);
end
$migration$;
