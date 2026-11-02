-- Run only against the isolated preview. No database changes are made.
DO $$
DECLARE item text; missing text[] := '{}';
BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to test outside isolated preview';
  END IF;
  FOREACH item IN ARRAY ARRAY[
    'admin_colonization_modifiers_api','admin_global_modifiers_api','admin_mercenaries_api',
    'admin_modifiers_api','admin_resources_api','colonization_api','estate_fiscal_api',
    'estate_investment_api','estate_social_api','fauxlore_api','garrison_api',
    'government_form_preview_api','instant_modifier_api','judge_assignments_api',
    'judge_state_statistics_api','local_events_api','map_revision_api','military_api',
    'military_map_api','military_order_api','military_split_api','military_transport_api',
    'militia_api','state_development_growth_api','state_journal_api','wall_api','wall_verdict_many'
  ] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND p.proname=item AND has_function_privilege('authenticated',p.oid,'EXECUTE')) THEN
      missing := array_append(missing,item);
    END IF;
  END LOOP;
  IF cardinality(missing)>0 THEN RAISE EXCEPTION 'Missing authenticated RPC permissions: %', missing; END IF;
  IF has_function_privilege('authenticated','public.projection_source_api()','EXECUTE') OR
     has_function_privilege('anon','public.projection_source_api()','EXECUTE') THEN
    RAISE EXCEPTION 'Private projection source is exposed';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname IN ('public','fauxlore') AND c.relkind IN ('r','v','m','p')
      AND (has_table_privilege('anon',c.oid,'SELECT') OR has_table_privilege('authenticated',c.oid,'SELECT'))) THEN
    RAISE EXCEPTION 'Unexpected direct table read permission';
  END IF;
END $$;
