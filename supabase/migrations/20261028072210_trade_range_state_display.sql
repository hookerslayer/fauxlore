-- Include principles in the trade-state options so the UI can show its actual range.
do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.trade_api(text,text,jsonb,uuid)'::regprocedure) into definition;
  marker:=$m$'id',c.id,'name',c.name$m$;
  replacement:=$m$'id',c.id,'name',c.name,'principles',sp.principles$m$;
  if position(marker in definition)=0 then raise exception 'Trade state list marker missing'; end if;
  execute replace(definition,marker,replacement);
end
$patch$;
notify pgrst,'reload schema';
