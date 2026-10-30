-- Reuse the authoritative trade agreement route checks for a read-only preview.
do $$
declare
  definition text;
begin
  select pg_get_functiondef('fauxlore.trade_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  if position('if path=''my/trade-agreements'' and method=''POST'' then' in definition)=0 then
    raise exception 'Trade proposal branch not found';
  end if;
  definition:=replace(definition,
    'if path=''my/trade-agreements'' and method=''POST'' then',
    'if path in (''my/trade-agreements'',''my/trade-agreements/preview-route'') and method=''POST'' then');
  if position('    from_goods:=coalesce(body->''from_goods'',''[]''::jsonb);' in definition)=0 then
    raise exception 'Trade goods validation boundary not found';
  end if;
  definition:=replace(definition,
    '    from_goods:=coalesce(body->''from_goods'',''[]''::jsonb);',
    '    if path=''my/trade-agreements/preview-route'' then
      return jsonb_build_object(''valid'',true,''route_length'',route_len,''route_limit'',route_limit);
    end if;
    from_goods:=coalesce(body->''from_goods'',''[]''::jsonb);');
  execute definition;

  select pg_get_functiondef('public.fauxlore_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  if position('path=''my/trade-agreements'' or path ~' in definition)=0 then
    raise exception 'Trade dispatcher branch not found';
  end if;
  definition:=replace(definition,
    'path=''my/trade-agreements'' or path ~',
    'path in (''my/trade-agreements'',''my/trade-agreements/preview-route'') or path ~');
  execute definition;
end $$;
