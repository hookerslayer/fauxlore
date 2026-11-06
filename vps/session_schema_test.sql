-- Isolated prototype only. Role grants for a production server are not defined.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to create prototype sessions outside the isolated copy';
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS fauxlore_vps_preview;
REVOKE ALL ON SCHEMA fauxlore_vps_preview FROM PUBLIC, anon, authenticated;
CREATE TABLE IF NOT EXISTS fauxlore_vps_preview.sessions (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  auth_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);
ALTER TABLE fauxlore_vps_preview.sessions ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
REVOKE ALL ON ALL TABLES IN SCHEMA fauxlore_vps_preview FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS fauxlore_vps_sessions_expiry_idx ON fauxlore_vps_preview.sessions(expires_at);
CREATE OR REPLACE FUNCTION fauxlore_vps_preview.lookup_google_user(google_subject text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE user_id uuid; matches bigint;
BEGIN
  SELECT count(*), (array_agg(a.auth_user_id))[1] INTO matches, user_id
  FROM fauxlore.accounts a
  JOIN auth.users u ON u.id=a.auth_user_id
  JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
  WHERE i.identity_data->>'sub'=google_subject AND a.google_sub=google_subject
    AND i.identity_data->>'email_verified'='true' AND u.email_confirmed_at IS NOT NULL
    AND u.deleted_at IS NULL AND (u.banned_until IS NULL OR u.banned_until <= now());
  IF matches <> 1 THEN RETURN NULL; END IF;
  RETURN user_id;
END $$;
CREATE OR REPLACE FUNCTION fauxlore_vps_preview.resolve_session(session_hash bytea)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
  SELECT s.auth_user_id FROM fauxlore_vps_preview.sessions s
  JOIN fauxlore.accounts a ON a.auth_user_id=s.auth_user_id
  JOIN auth.users u ON u.id=s.auth_user_id
  WHERE s.token_hash=session_hash AND s.expires_at > now()
    AND u.deleted_at IS NULL AND u.email_confirmed_at IS NOT NULL
    AND (u.banned_until IS NULL OR u.banned_until <= now())
    AND EXISTS (SELECT 1 FROM auth.identities i WHERE i.user_id=u.id AND i.provider='google'
      AND i.identity_data->>'email_verified'='true' AND i.identity_data->>'sub'=a.google_sub)
$$;
CREATE OR REPLACE FUNCTION fauxlore_vps_preview.renew_session(session_hash bytea, idle_seconds integer)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF idle_seconds < 1 OR idle_seconds > 43200 THEN RETURN false; END IF;
  UPDATE fauxlore_vps_preview.sessions s
    SET expires_at=LEAST(now() + (idle_seconds * interval '1 second'), s.created_at + interval '30 days')
    FROM fauxlore.accounts a, auth.users u
    WHERE s.token_hash=session_hash AND s.expires_at > now()
      AND a.auth_user_id=s.auth_user_id AND u.id=s.auth_user_id
      AND u.deleted_at IS NULL AND u.email_confirmed_at IS NOT NULL
      AND (u.banned_until IS NULL OR u.banned_until <= now())
      AND EXISTS (SELECT 1 FROM auth.identities i WHERE i.user_id=u.id AND i.provider='google'
        AND i.identity_data->>'email_verified'='true' AND i.identity_data->>'sub'=a.google_sub);
  RETURN FOUND;
END $$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fauxlore_vps_preview FROM PUBLIC, anon, authenticated;
COMMIT;
