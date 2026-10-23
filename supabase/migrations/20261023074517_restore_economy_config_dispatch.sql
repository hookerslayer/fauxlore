-- Restore config routing lost in an earlier dispatcher rewrite.
do $$
declare fn text; marker text:='if path ~ ''^(my|admin)/states/[0-9]+/trade-duty$'' then';
begin
fn:=pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure);
if position(marker in fn)=0 then raise exception 'Config dispatcher marker missing'; end if;
execute replace(fn,marker,'if path in (''economy/config'',''admin/economy/config'') then return fauxlore.economy_config_api(path,method,body,request_id);'||chr(10)||' els'||marker);
end $$;
notify pgrst,'reload schema';
