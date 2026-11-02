do $migration$
declare fn text; marker text;
begin
 fn:=pg_get_functiondef('fauxlore.spend_tradition(integer,text,numeric)'::regprocedure);
 marker:=$old$effective:=fauxlore.effective_tradition(target_state,domain_value);$old$;
 if position(marker in fn)=0 then raise exception 'tradition zero guard missing';end if;
 fn:=replace(fn,marker,marker||' if effective<=0 or amount=0 then return; end if;');execute fn;
end $migration$;
