-- Isolated prototype: reject sessions for deleted, blocked or unverified users.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to change authentication outside isolated preview';
  END IF;
END $$;
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
REVOKE ALL ON FUNCTION fauxlore_vps_preview.lookup_google_user(text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION fauxlore_vps_preview.resolve_session(bytea) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.lookup_google_user(text) TO fauxlore_auth;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.resolve_session(bytea) TO fauxlore_auth,fauxlore_rpc;
COMMIT;
