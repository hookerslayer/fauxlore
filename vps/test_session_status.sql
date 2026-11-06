-- All fixture sessions and temporary status changes are rolled back.
BEGIN;
DO $$ DECLARE uid uuid; subject text; BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN RAISE EXCEPTION 'Wrong database'; END IF;
  SELECT a.auth_user_id,a.google_sub INTO uid,subject FROM fauxlore.accounts a
    JOIN auth.users u ON u.id=a.auth_user_id JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
    WHERE a.google_sub=i.identity_data->>'sub' AND i.identity_data->>'email_verified'='true'
      AND u.deleted_at IS NULL AND u.email_confirmed_at IS NOT NULL
      AND (u.banned_until IS NULL OR u.banned_until<=now()) LIMIT 1;
  IF uid IS NULL THEN RAISE EXCEPTION 'Missing linked user fixture'; END IF;
  PERFORM set_config('test.session_user',uid::text,true);
  PERFORM set_config('test.session_subject',subject,true);
  INSERT INTO fauxlore_vps_preview.sessions(token_hash,auth_user_id,created_at,expires_at)
    VALUES (decode(repeat('ab',32),'hex'),uid,now(),now()+interval '1 hour');
END $$;
SET LOCAL ROLE fauxlore_auth;
DO $$ BEGIN
  IF fauxlore_vps_preview.lookup_google_user(current_setting('test.session_subject')) IS DISTINCT FROM current_setting('test.session_user')::uuid OR
     fauxlore_vps_preview.resolve_session(decode(repeat('ab',32),'hex')) IS DISTINCT FROM current_setting('test.session_user')::uuid THEN
    RAISE EXCEPTION 'Active user could not sign in or resolve session';
  END IF;
END $$;
RESET ROLE;
UPDATE auth.users SET banned_until=now()+interval '1 hour' WHERE id=current_setting('test.session_user')::uuid;
SET LOCAL ROLE fauxlore_auth;
DO $$ BEGIN
  IF fauxlore_vps_preview.lookup_google_user(current_setting('test.session_subject')) IS NOT NULL OR
     fauxlore_vps_preview.resolve_session(decode(repeat('ab',32),'hex')) IS NOT NULL THEN
    RAISE EXCEPTION 'Blocked account was allowed';
  END IF;
END $$;
RESET ROLE;
UPDATE auth.users SET banned_until=NULL,deleted_at=now() WHERE id=current_setting('test.session_user')::uuid;
SET LOCAL ROLE fauxlore_auth;
DO $$ BEGIN
  IF fauxlore_vps_preview.lookup_google_user(current_setting('test.session_subject')) IS NOT NULL OR
     fauxlore_vps_preview.resolve_session(decode(repeat('ab',32),'hex')) IS NOT NULL THEN
    RAISE EXCEPTION 'Deleted account was allowed';
  END IF;
END $$;
ROLLBACK;
