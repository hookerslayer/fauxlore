-- Keep naval militia upkeep visible in forecasts even if its land formation was lost.
do $patch$
declare definition text; marker text; replacement text;
begin
  definition:=pg_get_functiondef('fauxlore.militia_crown_upkeep(integer)'::regprocedure);
  marker:='join fauxlore.military_formations f on f.id=m.formation_id and f.active and f.kind=''militia''';
  replacement:='left join fauxlore.military_formations f on f.id=m.formation_id and f.active and f.kind=''militia''';
  if position(marker in definition)=0 then
    if position(replacement in definition)=0 then raise exception 'Militia land formation forecast join not found'; end if;
  else
    definition:=replace(definition,marker,replacement);
  end if;
  marker:='where m.state_id=state_key and m.status=''active''';
  replacement:='where m.state_id=state_key and m.status=''active'' and (f.id is not null or exists(select 1 from fauxlore.military_formations nf where nf.id=m.naval_formation_id and nf.active and nf.kind=''militia''))';
  if position(marker in definition)>0 then
    definition:=replace(definition,marker,replacement);
  elsif position(replacement in definition)=0 then
    raise exception 'Militia active formation forecast condition not found';
  end if;
  execute definition;
end
$patch$;
