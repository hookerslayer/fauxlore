-- Route the trade endpoints through their existing, permission-checked handlers.
-- The latest dispatcher rewrite accidentally sent these GET requests to the
-- legacy API, which rejects unknown read routes with "Метод API не найден".
do $$
declare
  definition text;
  marker text := 'elsif path=''admin/turn/test'' or path like ''admin/turn/test/%'' then return fauxlore.test_turn_api(path,method,body,request_id);';
  routes text := 'elsif path=''my/trade-agreements'' or path ~ ''^(my|admin)/trade-agreements/[0-9]+/(accept|decline|cancel)$'' then return fauxlore.trade_api(path,method,body,request_id);'||chr(10)||
    '  elsif path=''my/trade-settlements'' then return fauxlore.trade_api(path,method,body,request_id);'||chr(10)||
    '  elsif path=''my/trade-market'' then return fauxlore.trade_market_api(path,method,body,request_id);'||chr(10)||
    '  elsif path=''my/trade-interzone'' then return fauxlore.trade_interzone_api(path,method,body,request_id);'||chr(10)||
    '  elsif path ~ ''^my/trade-availability/[0-9]+$'' then return fauxlore.trade_availability_api(path,method,body,request_id);'||chr(10)||'  ';
begin
  select pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  if position('path=''my/trade-agreements''' in definition)=0 then
    if position(marker in definition)=0 then
      raise exception 'Expected dispatcher insertion point not found in public.fauxlore_api';
    end if;
    execute replace(definition,marker,routes||marker);
  end if;
end $$;
