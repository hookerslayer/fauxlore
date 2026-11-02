-- Isolated prototype only; the PostgREST listener stays on loopback.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to configure PostgREST outside isolated preview';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fauxlore_postgrest') THEN
    CREATE ROLE fauxlore_postgrest LOGIN NOINHERIT;
  END IF;
END $$;
GRANT anon, authenticated TO fauxlore_postgrest;
GRANT CONNECT ON DATABASE fauxlore_restore_filtered TO fauxlore_postgrest;
GRANT EXECUTE ON FUNCTION public.map_revision_api() TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.map_revision() TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.turn_api(text,text,jsonb,uuid) TO authenticated;
-- Application functions granted explicitly in the checked-in Supabase schema.
GRANT EXECUTE ON FUNCTION public.government_form_preview_api(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.military_api(text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.colonization_api(text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.colonization_api(text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.militia_api(text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.garrison_api(text,integer,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.estate_investment_api(text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.estate_social_api(text,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.estate_fiscal_api(text,integer,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.military_map_api() TO authenticated;
GRANT EXECUTE ON FUNCTION public.military_order_api(text,bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.military_split_api(bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.military_transport_api(text,bigint,bigint,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.state_development_growth_api(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resources_api(text,integer,text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.admin_resources_api(text,integer,text,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_global_modifiers_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mercenaries_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_colonization_modifiers_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.admin_colonization_modifiers_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.judge_assignments_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.judge_state_statistics_api() TO authenticated;
GRANT EXECUTE ON FUNCTION public.instant_modifier_api(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_modifiers_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.admin_modifiers_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wall_verdict_many(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.wall_verdict_many(jsonb) TO authenticated;
-- Dispatch targets are granted individually; direct table privileges remain revoked.
GRANT EXECUTE ON FUNCTION fauxlore.economy_config_api(text,text,jsonb,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.character_lifecycle_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.characters_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.marriage_dissolution_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.dynastic_marriage_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.abdicate_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.succession_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.registration_api_with_surname(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.my_applications() TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.application_details(text,text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.state_emblem_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.army_budget_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.turn_budget_report_api(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.group_status_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.transit_toll_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.state_estate_loans_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.trade_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.trade_market_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.trade_interzone_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.trade_availability_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.trade_route_transit_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.diplomatic_proposals_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.admin_marker_character_edit_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.test_turn_api(text,text,jsonb,uuid) TO authenticated;
COMMIT;
