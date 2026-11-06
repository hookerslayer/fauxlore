-- Restricted role for a loopback-only prototype; not a public deployment.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing RPC role setup outside the isolated copy';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fauxlore_rpc') THEN
    CREATE ROLE fauxlore_rpc LOGIN NOINHERIT;
  ELSIF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fauxlore_rpc'
                AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR rolinherit OR NOT rolcanlogin)) THEN
    RAISE EXCEPTION 'Existing fauxlore_rpc role has unexpected privileges';
  END IF;
END $$;
GRANT CONNECT ON DATABASE fauxlore_restore_filtered TO fauxlore_rpc;
GRANT authenticated TO fauxlore_rpc;
GRANT USAGE ON SCHEMA fauxlore_vps_preview TO fauxlore_rpc;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.resolve_session(bytea) TO fauxlore_rpc;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.renew_session(bytea,integer) TO fauxlore_rpc;
COMMIT;
