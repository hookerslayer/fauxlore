do $migration$
declare fn text; marker text; replacement text;
begin
 fn:=pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure);
 marker:=$old$select ac.id from fauxlore.accounts ac where ac.role='admin'$old$;
 replacement:=$new$select ac.id from fauxlore.accounts ac where ac.role='admin' and final_value<40 and roll_value between 0 and 10$new$;
 if position(marker in fn)=0 then raise exception 'Colonization notification recipient hook missing'; end if;
 fn:=replace(fn,marker,replacement);
 marker:=$old$where ast.layer='states' and ast.state_id=state_key$old$;
 replacement:=$new$where ast.layer='states' and ast.state_id=state_key and (not exists(select 1 from fauxlore.accounts owner_account where owner_account.id=ast.account_id and owner_account.role='admin') or (final_value<40 and roll_value between 0 and 10))$new$;
 if position(marker in fn)=0 then raise exception 'Colonization owner recipient hook missing'; end if;
 execute replace(fn,marker,replacement);
end
$migration$;
