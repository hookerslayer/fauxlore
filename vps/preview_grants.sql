-- Apply ONLY to the isolated copy; the dump deliberately omitted ACLs.
BEGIN;
DO $$
BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to change privileges outside the isolated preview database';
  END IF;
END $$;
REVOKE ALL ON SCHEMA public, fauxlore FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public, fauxlore FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA fauxlore FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public, fauxlore TO anon;
GRANT EXECUTE ON FUNCTION public.fauxlore_api(text,text,jsonb,uuid) TO anon;
GRANT EXECUTE ON FUNCTION fauxlore.api(text,text,jsonb,uuid) TO anon;
GRANT EXECUTE ON FUNCTION fauxlore.turn_api(text,text,jsonb,uuid) TO anon;
GRANT EXECUTE ON FUNCTION fauxlore.game_state_api(text,text,jsonb,uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.map_revision_api() TO anon;
GRANT EXECUTE ON FUNCTION fauxlore.map_revision() TO anon;
GRANT EXECUTE ON FUNCTION public.wall_api(text,jsonb) TO anon;
GRANT EXECUTE ON FUNCTION fauxlore.wall_api(text,jsonb) TO anon;
-- These additional grants permit isolated role tests, not an exposed login API.
GRANT USAGE ON SCHEMA public, fauxlore TO authenticated;
GRANT EXECUTE ON FUNCTION public.fauxlore_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.game_state_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.state_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.registration_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.state_indicators_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.local_events_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.state_journal_api(text,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wall_api(text,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.wall_api(text,jsonb) TO authenticated;
COMMIT;
