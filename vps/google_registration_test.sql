-- Isolated prototype only. The caller must verify the Google token first.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to configure registration outside isolated preview';
  END IF;
END $$;
CREATE OR REPLACE FUNCTION fauxlore_vps_preview.create_google_user(google_subject text, verified_email text, display_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE new_id uuid; existing_id uuid; identity_count bigint; normalized_email text; safe_name text;
BEGIN
  normalized_email := lower(btrim(verified_email));
  IF google_subject IS NULL OR length(google_subject) NOT BETWEEN 1 AND 255 OR
     google_subject !~ '^[!-~]+$' OR normalized_email IS NULL OR length(normalized_email) NOT BETWEEN 3 AND 254 OR
     normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+$' THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('google-sub:' || google_subject, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('google-email:' || normalized_email, 0));
  -- Reuse only an existing, verified Google identity with the same subject,
  -- never an account discovered solely through a matching email.
  SELECT count(*), (array_agg(i.user_id))[1] INTO identity_count, existing_id
  FROM auth.identities i WHERE i.provider='google' AND
    (i.provider_id=google_subject OR i.identity_data->>'sub'=google_subject);
  IF identity_count > 1 OR EXISTS (SELECT 1 FROM fauxlore.accounts
      WHERE google_sub=google_subject OR lower(email)=normalized_email OR auth_user_id=existing_id) THEN RETURN NULL; END IF;
  safe_name := left(coalesce(nullif(btrim(display_name),''),split_part(normalized_email,'@',1)),40);
  IF identity_count = 1 THEN
    IF NOT EXISTS (SELECT 1 FROM auth.identities i JOIN auth.users u ON u.id=i.user_id
      WHERE i.user_id=existing_id AND i.provider='google' AND i.identity_data->>'sub'=google_subject
        AND i.identity_data->>'email_verified'='true' AND lower(u.email)=normalized_email
        AND u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL
        AND (u.banned_until IS NULL OR u.banned_until<=now())) THEN RETURN NULL; END IF;
    INSERT INTO fauxlore.accounts(auth_user_id,email,nickname,google_sub)
      VALUES(existing_id,normalized_email,safe_name,google_subject);
    RETURN existing_id;
  END IF;
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email)=normalized_email) THEN RETURN NULL; END IF;
  new_id := gen_random_uuid();
  INSERT INTO auth.users(id,aud,role,email,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    VALUES(new_id,'authenticated','authenticated',normalized_email,now(),
           jsonb_build_object('provider','google','providers',jsonb_build_array('google')),
           jsonb_build_object('name',safe_name),now(),now());
  INSERT INTO auth.identities(provider_id,user_id,identity_data,provider,created_at,updated_at)
    VALUES(google_subject,new_id,jsonb_build_object('sub',google_subject,'email',normalized_email,
           'email_verified',true,'name',safe_name),'google',now(),now());
  INSERT INTO fauxlore.accounts(auth_user_id,email,nickname,google_sub)
    VALUES(new_id,normalized_email,safe_name,google_subject);
  RETURN new_id;
END $$;
REVOKE ALL ON FUNCTION fauxlore_vps_preview.create_google_user(text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.create_google_user(text,text,text) TO fauxlore_auth;
COMMIT;
