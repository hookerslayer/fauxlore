-- Narrow database privileges for the isolated authentication prototype only.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to grant prototype access outside the isolated copy';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fauxlore_auth') THEN
    CREATE ROLE fauxlore_auth LOGIN NOINHERIT;
  ELSIF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fauxlore_auth'
                AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR rolinherit OR NOT rolcanlogin)) THEN
    RAISE EXCEPTION 'Existing fauxlore_auth role has unexpected privileges';
  END IF;
END $$;
GRANT CONNECT ON DATABASE fauxlore_restore_filtered TO fauxlore_auth;
GRANT USAGE ON SCHEMA fauxlore_vps_preview TO fauxlore_auth;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.lookup_google_user(text) TO fauxlore_auth;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.resolve_session(bytea) TO fauxlore_auth;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.renew_session(bytea,integer) TO fauxlore_auth;
REVOKE ALL ON fauxlore_vps_preview.sessions FROM fauxlore_auth;
GRANT SELECT (token_hash) ON fauxlore_vps_preview.sessions TO fauxlore_auth;
GRANT INSERT (token_hash, auth_user_id, created_at, expires_at) ON fauxlore_vps_preview.sessions TO fauxlore_auth;
GRANT DELETE ON fauxlore_vps_preview.sessions TO fauxlore_auth;
COMMIT;
