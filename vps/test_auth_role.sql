-- Role isolation test on the snapshot. Test session rows are rolled back.
BEGIN;
DO $$ DECLARE subject text; user_id uuid; BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Role test requires the isolated preview database';
  END IF;
  IF has_schema_privilege('fauxlore_auth','auth','USAGE') OR
     has_table_privilege('fauxlore_auth','fauxlore.accounts','SELECT') OR
     pg_has_role('fauxlore_auth','authenticated','MEMBER') THEN
    RAISE EXCEPTION 'Authentication role is overprivileged';
  END IF;
  SELECT i.identity_data->>'sub', a.auth_user_id INTO subject, user_id
  FROM fauxlore.accounts a JOIN auth.users u ON u.id=a.auth_user_id
  JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
  WHERE i.identity_data->>'email_verified'='true' AND u.email_confirmed_at IS NOT NULL LIMIT 1;
  IF subject IS NULL OR user_id IS NULL THEN RAISE EXCEPTION 'No verified fixture'; END IF;
  PERFORM set_config('test.google_subject',subject,true);
  PERFORM set_config('test.user_id',user_id::text,true);
END $$;
SET LOCAL ROLE fauxlore_auth;
DO $$ DECLARE digest bytea := decode(repeat('ab',32),'hex'); BEGIN
  IF fauxlore_vps_preview.lookup_google_user(current_setting('test.google_subject'))
      IS DISTINCT FROM current_setting('test.user_id')::uuid THEN
    RAISE EXCEPTION 'Google subject did not resolve';
  END IF;
  IF fauxlore_vps_preview.lookup_google_user('nonexistent-test-subject') IS NOT NULL THEN
    RAISE EXCEPTION 'Unknown Google subject resolved';
  END IF;
  INSERT INTO fauxlore_vps_preview.sessions(token_hash,auth_user_id,expires_at)
  VALUES (digest,current_setting('test.user_id')::uuid,now()+interval '1 minute');
  IF fauxlore_vps_preview.resolve_session(digest) IS DISTINCT FROM current_setting('test.user_id')::uuid THEN
    RAISE EXCEPTION 'Session did not resolve';
  END IF;
  DELETE FROM fauxlore_vps_preview.sessions WHERE token_hash=digest;
  IF fauxlore_vps_preview.resolve_session(digest) IS NOT NULL THEN
    RAISE EXCEPTION 'Revoked session resolved';
  END IF;
END $$;
ROLLBACK;
