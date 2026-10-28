-- Apply local colonization duration modifiers to mission completion and display.
do $patch$
declare definition text; marker text; replacement text;
begin
  select pg_get_functiondef('fauxlore.advance_colonization_missions()'::regprocedure) into definition;
  marker:=$m$declare m record; crown_balance numeric; current_year integer; current_turn integer; state_name text;$m$;
  if position(marker in definition)=0 then raise exception 'Could not locate colonization turn declarations'; end if;
  definition:=replace(definition,marker,marker||' duration_value integer;');
  marker:=$m$if m.elapsed_turns>=3 then$m$;
  replacement:=$m$duration_value:=greatest(1,4+floor(fauxlore.state_permanent_modifier_total(m.state_id,array['colonization_duration'],m.province_id,null))::integer);
    if m.elapsed_turns>=duration_value-1 then$m$;
  if position(marker in definition)=0 then raise exception 'Could not locate colonization completion threshold'; end if;
  definition:=replace(definition,marker,replacement);
  definition:=replace(definition,'elapsed_turns=4,upkeep_paid','elapsed_turns=duration_value,upkeep_paid');
  execute definition;

  select pg_get_functiondef('fauxlore.colonization_api(text,integer,jsonb)'::regprocedure) into definition;
  marker:=$m$'turns_remaining',4-m.elapsed_turns$m$;
  replacement:=$m$'turns_remaining',greatest(0,4+floor(fauxlore.state_permanent_modifier_total(m.state_id,array['colonization_duration'],m.province_id,null))::integer-m.elapsed_turns)$m$;
  if position(marker in definition)=0 then raise exception 'Could not locate colonization duration display'; end if;
  definition:=replace(definition,marker,replacement);
  execute definition;
end
$patch$;
