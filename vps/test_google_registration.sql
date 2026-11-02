-- Synthetic registration fixtures only; transaction rolls back.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN RAISE EXCEPTION 'Wrong database'; END IF;
  IF has_function_privilege('authenticated','fauxlore_vps_preview.create_google_user(text,text,text)','EXECUTE') OR
     has_function_privilege('anon','fauxlore_vps_preview.create_google_user(text,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Registration helper exposed to client roles';
  END IF;
  PERFORM set_config('test.google_subject','synthetic-' || gen_random_uuid()::text,true);
  PERFORM set_config('test.google_email','synthetic-' || gen_random_uuid()::text || '@example.invalid',true);
  PERFORM set_config('test.existing_email',(SELECT email FROM fauxlore.accounts ORDER BY id LIMIT 1),true);
  PERFORM set_config('test.orphan_user',gen_random_uuid()::text,true);
  PERFORM set_config('test.orphan_subject','orphan-' || gen_random_uuid()::text,true);
  PERFORM set_config('test.orphan_email','orphan-' || gen_random_uuid()::text || '@example.invalid',true);
  INSERT INTO auth.users(id,email,email_confirmed_at,created_at,updated_at)
    VALUES(current_setting('test.orphan_user')::uuid,current_setting('test.orphan_email'),now(),now(),now());
  INSERT INTO auth.identities(provider_id,user_id,identity_data,provider,created_at,updated_at)
    VALUES(current_setting('test.orphan_subject'),current_setting('test.orphan_user')::uuid,
      jsonb_build_object('sub',current_setting('test.orphan_subject'),'email_verified',true), 'google',now(),now());
END $$;
UPDATE auth.users SET banned_until=now()+interval '1 hour' WHERE id=current_setting('test.orphan_user')::uuid;
SET LOCAL ROLE fauxlore_auth;
DO $$ BEGIN
  IF fauxlore_vps_preview.create_google_user(current_setting('test.orphan_subject'),
       current_setting('test.orphan_email'),'Orphan Player') IS NOT NULL THEN
    RAISE EXCEPTION 'Blocked existing identity was registered';
  END IF;
END $$;
RESET ROLE;
UPDATE auth.users SET banned_until=NULL WHERE id=current_setting('test.orphan_user')::uuid;
UPDATE auth.identities SET identity_data=jsonb_set(identity_data,'{email_verified}','false'::jsonb)
  WHERE user_id=current_setting('test.orphan_user')::uuid AND provider='google';
SET LOCAL ROLE fauxlore_auth;
DO $$ BEGIN
  IF fauxlore_vps_preview.create_google_user(current_setting('test.orphan_subject'),
       current_setting('test.orphan_email'),'Orphan Player') IS NOT NULL THEN
    RAISE EXCEPTION 'Unverified existing identity was registered';
  END IF;
END $$;
RESET ROLE;
UPDATE auth.identities SET identity_data=jsonb_set(identity_data,'{email_verified}','true'::jsonb)
  WHERE user_id=current_setting('test.orphan_user')::uuid AND provider='google';
SET LOCAL ROLE fauxlore_auth;
DO $$ DECLARE uid uuid; BEGIN
  uid := fauxlore_vps_preview.create_google_user(current_setting('test.google_subject'),current_setting('test.google_email'),'Test Player');
  IF uid IS NULL THEN RAISE EXCEPTION 'Registration failed'; END IF;
  IF fauxlore_vps_preview.lookup_google_user(current_setting('test.google_subject')) IS DISTINCT FROM uid THEN
    RAISE EXCEPTION 'New identity cannot be resolved';
  END IF;
  IF fauxlore_vps_preview.create_google_user('another-subject-' || uid::text,current_setting('test.google_email'),'Other') IS NOT NULL THEN
    RAISE EXCEPTION 'Email collision linked or created an account';
  END IF;
  IF fauxlore_vps_preview.create_google_user(current_setting('test.google_subject'),'different-' || uid::text || '@example.invalid','Other') IS NOT NULL THEN
    RAISE EXCEPTION 'Duplicate subject created an account';
  END IF;
  IF fauxlore_vps_preview.create_google_user('collision-' || uid::text,current_setting('test.existing_email'),'Other') IS NOT NULL THEN
    RAISE EXCEPTION 'Existing account was linked by email';
  END IF;
  IF fauxlore_vps_preview.create_google_user('invalid-' || uid::text,'not-an-email','Other') IS NOT NULL THEN
    RAISE EXCEPTION 'Invalid email accepted';
  END IF;
  IF fauxlore_vps_preview.create_google_user(current_setting('test.orphan_subject'),
       'wrong-' || uid::text || '@example.invalid','Other') IS NOT NULL THEN
    RAISE EXCEPTION 'Mismatched email was accepted for existing identity';
  END IF;
  IF fauxlore_vps_preview.create_google_user(current_setting('test.orphan_subject'),
       current_setting('test.orphan_email'),'Orphan Player') IS DISTINCT FROM current_setting('test.orphan_user')::uuid THEN
    RAISE EXCEPTION 'Verified existing identity without game profile could not register';
  END IF;
  PERFORM set_config('test.google_user_id',uid::text,true);
END $$;
RESET ROLE;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM fauxlore.accounts WHERE auth_user_id=current_setting('test.google_user_id')::uuid AND role='player') THEN
    RAISE EXCEPTION 'New account was not created as player';
  END IF;
END $$;
ROLLBACK;
