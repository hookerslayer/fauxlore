-- Correct resource-specific modifiers and apply militia coefficients to the
-- established muster calculation, keeping unit composition system-generated.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('fauxlore.state_permanent_modifier_total(integer,text[],integer,text)'::regprocedure);
  marker:='if row_value->>''key''=''precious_consumption''';
  replacement:='if row_value->>''key''=''metal_production'' and target_resource not in (''Металлы'',''Драгоценные металлы'') then continue; end if;'||chr(10)||
    '    if row_value->>''key''=''ephemera_production'' and target_resource is distinct from ''Эфемера'' then continue; end if;'||chr(10)||marker;
  if position(marker in fn)=0 then raise exception 'Resource modifier filter insertion point missing'; end if;
  execute replace(fn,marker,replacement);

  fn:=pg_get_functiondef('fauxlore.militia_preview(integer)'::regprocedure);
  marker:='select coefficient into coeff from fauxlore.militia_settings where singleton;';
  replacement:=marker||chr(10)||
    '  coeff:=coeff*(1+fauxlore.state_permanent_modifier_total(state_key,array[''militia_coefficient'',''militia_potential''],null,null));';
  if position(marker in fn)=0 then raise exception 'Militia coefficient insertion point missing'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='count_value:=floor(estate_row.population*rate*status_factor*(.5+avg_loyalty/2)';
  replacement:='count_value:=floor(estate_row.population*rate*status_factor*(.5+avg_loyalty/2)'||
    '*(1+case estate_row.estate when ''Знать'' then fauxlore.state_permanent_modifier_total(state_key,array[''militia_nobility''],null,null)'||
    ' when ''Духовенство'' then fauxlore.state_permanent_modifier_total(state_key,array[''militia_clergy''],null,null) else 0 end)';
  if position(marker in fn)=0 then raise exception 'Estate militia modifier insertion point missing'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

-- Recruitment and upkeep prices use additive modifiers from all active sources.
do $migration$
declare fn text; marker text; replacement text;
begin
  fn:=pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  marker:='price:=amount*unit_row.hire_cost;';
  replacement:='price:=floor(amount*unit_row.hire_cost*greatest(0,1+fauxlore.state_permanent_modifier_total(sid,array_remove(array['||
    'case when unit_row.domain=''naval'' then ''fleet_hire_cost'' end,'||
    'case when unit_row.domain=''naval'' then ''ship_hire_cost'' end,'||
    'case when unit_row.category=''Кавалерия'' then ''cavalry_hire_cost'' end,'||
    'case when unit_row.name=''Лучник'' then ''archer_hire_cost'' end,'||
    'case when unit_row.name=''Арбалетчик'' then ''crossbow_hire_cost'' end,'||
    'case when unit_row.name=''Пищальник'' or unit_row.domain=''siege'' then ''firearms_hire_cost'' end,'||
    'case when unit_row.domain in (''land'',''siege'') then ''regular_hire_cost'' end]::text[],null),null,null)));';
  if position(marker in fn)=0 then raise exception 'Military hire cost insertion point missing'; end if;
  execute replace(fn,marker,replacement);
  fn:=pg_get_functiondef('fauxlore.charge_army_upkeep_before_turn()'::regprocedure);
  marker:='where f.state_id=state_row.state_id and f.active and f.kind<>''militia'' order by f.id loop';
  if position(marker in fn)=0 then raise exception 'Army upkeep loop marker missing'; end if;
  marker:='cost:=case when formation_row.kind=''mercenary'' then formation_row.mercenary_price else formation_row.regular_cost end;';
  replacement:='cost:=case when formation_row.kind=''mercenary'' then formation_row.mercenary_price*greatest(0,1+fauxlore.state_permanent_modifier_total(state_row.state_id,array[''mercenary_upkeep''],null,null)) else formation_row.regular_cost end;';
  if position(marker in fn)=0 then raise exception 'Army upkeep cost assignment missing'; end if;
  fn:=replace(fn,marker,replacement);
  marker:='else fu.quantity*u.upkeep end),0) from fauxlore.military_formation_units fu';
  replacement:='else fu.quantity*u.upkeep*greatest(0,1+fauxlore.state_permanent_modifier_total(f.state_id,array_remove(array['||
    'case when u.domain=''naval'' then ''fleet_upkeep'' end,'||
    'case when u.domain=''naval'' then ''ship_upkeep'' end,'||
    'case when u.category=''Кавалерия'' then ''cavalry_upkeep'' end,'||
    'case when u.name=''Лучник'' then ''archer_upkeep'' end,'||
    'case when u.name=''Арбалетчик'' then ''crossbow_upkeep'' end,'||
    'case when u.name=''Пищальник'' or u.domain=''siege'' then ''firearms_upkeep'' end,'||
    'case when u.domain in (''land'',''siege'') then ''regular_upkeep'' end]::text[],null),null,null)) end),0) from fauxlore.military_formation_units fu';
  if position(marker in fn)=0 then raise exception 'Army unit upkeep expression missing'; end if;
  execute replace(fn,marker,replacement);
end
$migration$;

notify pgrst,'reload schema';
