-- The military snapshot used to rebuild the full permanent-modifier JSON once
-- per province while checking control. Cache the state-level control modifier
-- for snapshots that have no province-scoped control overrides. States with
-- local overrides keep the existing per-province calculation unchanged.
DO $migration$
DECLARE
  definition text;
  marker text;
  replacement text;
BEGIN
  definition := pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);

  marker := 'indicator_snapshot jsonb;';
  IF length(definition) - length(replace(definition, marker, '')) <> length(marker) THEN
    RAISE EXCEPTION 'Military snapshot declaration marker is missing or ambiguous';
  END IF;
  definition := replace(definition, marker,
    'indicator_snapshot jsonb; control_modifier numeric; local_control_modifiers boolean;');

  marker := 'indicator_snapshot:=fauxlore.state_indicators(sid);';
  IF length(definition) - length(replace(definition, marker, '')) <> length(marker) THEN
    RAISE EXCEPTION 'Military snapshot setup marker is missing or ambiguous';
  END IF;
  replacement := marker || E'\n  ' ||
    'control_modifier:=fauxlore.state_permanent_modifier_total(sid,array[''control_modifier_pp''],NULL,NULL);' || E'\n  ' ||
    'local_control_modifiers:=EXISTS(SELECT 1 FROM jsonb_array_elements(fauxlore.state_permanent_modifiers(sid)) modifier ' ||
    'WHERE modifier->>''key''=''control_modifier_pp'' AND ' ||
    '(modifier->>''target_province_id'' IS NOT NULL OR coalesce(modifier->>''scope'','''')<>''Государство''));';
  definition := replace(definition, marker, replacement);

  marker := 'fauxlore.effective_province_control(p.id,sid)=100';
  IF length(definition) - length(replace(definition, marker, '')) <> length(marker) THEN
    RAISE EXCEPTION 'Military snapshot province-control marker is missing or ambiguous';
  END IF;
  definition := replace(definition, marker,
    'case when local_control_modifiers then fauxlore.effective_province_control(p.id,sid)=100 ' ||
    'else greatest(0,least(100,coalesce(p.control,100)+100*control_modifier))=100 end');

  EXECUTE definition;
END
$migration$;

-- The finance projection needs only military upkeep, not the full military
-- snapshot (province map, unit catalog, leaders, diplomacy and battles).
DO $migration$
DECLARE
  definition text;
  marker text := 'elsif action=''admin_queue'' then';
BEGIN
  definition := pg_get_functiondef('public.military_api(text,integer,jsonb)'::regprocedure);
  IF length(definition) - length(replace(definition, marker, '')) <> length(marker) THEN
    RAISE EXCEPTION 'Military snapshot action insertion marker is missing or ambiguous';
  END IF;
  definition := replace(definition, marker,
    'elsif action=''upkeep_snapshot'' then' || E'\n  ' ||
    'return jsonb_build_object(''upkeep_breakdown'',fauxlore.military_upkeep_summary(sid));' || E'\n ' || marker);
  EXECUTE definition;
END
$migration$;

NOTIFY pgrst, 'reload schema';
