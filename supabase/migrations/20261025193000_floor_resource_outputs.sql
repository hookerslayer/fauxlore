-- Production and consumption are integer resource quantities.
do $migration$
declare fn text; changed text; signature text;
begin
  foreach signature in array array[
    'fauxlore.clear_trade_zones_after_budget()'::regprocedure::text,
    'fauxlore.finish_trade_value_turn()'::regprocedure::text,
    'fauxlore.trade_resource_surplus(integer,text)'::regprocedure::text,
    'fauxlore.report_food_security_after_turn()'::regprocedure::text
  ] loop
    fn:=pg_get_functiondef(signature::regprocedure);
    changed:=replace(fn,'round(greatest(p.population,0)::numeric*(rc.r->>''production'')::numeric*','floor(greatest(p.population,0)::numeric*(rc.r->>''production'')::numeric*');
    changed:=replace(changed,'round(greatest(p.population,0)::numeric*(res.r->>''production'')::numeric*','floor(greatest(p.population,0)::numeric*(res.r->>''production'')::numeric*');
    changed:=replace(changed,',0) amount',') amount');
    changed:=replace(changed,',0)),0) amount', ')),0) amount');
    changed:=replace(changed,',0)),0)::numeric amount', ')),0)::numeric amount');
    changed:=replace(changed,'ceil(', 'floor(');
    if changed<>fn then execute changed; end if;
  end loop;
end
$migration$;
