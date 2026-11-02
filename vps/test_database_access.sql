-- Tests only the restored snapshot. No OAuth login is performed here.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Access tests require the isolated preview database';
  END IF;
END $$;

SET LOCAL ROLE anon;
DO $$ BEGIN
  IF public.fauxlore_api('auth/me','GET','{}'::jsonb,NULL)->'user' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'Guest unexpectedly has an identity';
  END IF;
  BEGIN
    PERFORM 1 FROM fauxlore.accounts LIMIT 1;
    RAISE EXCEPTION 'Guest can read accounts directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

DO $$ DECLARE actor uuid; BEGIN
  SELECT a.auth_user_id INTO actor FROM fauxlore.accounts a
    JOIN auth.users u ON u.id=a.auth_user_id
    JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
    WHERE a.role='player' AND u.email_confirmed_at IS NOT NULL
      AND i.identity_data->>'email_verified'='true' LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'No verified player in snapshot'; END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  IF public.fauxlore_api('auth/me','GET','{}'::jsonb,NULL)->'user'->>'role' <> 'player' THEN
    RAISE EXCEPTION 'Player identity does not resolve';
  END IF;
  IF jsonb_typeof(public.fauxlore_api('my/states','GET','{}'::jsonb,NULL)) <> 'array' THEN
    RAISE EXCEPTION 'Player states response is invalid';
  END IF;
  BEGIN
    PERFORM public.fauxlore_api('admin/states','GET','{}'::jsonb,NULL);
    RAISE EXCEPTION 'Player can access administrator states';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

DO $$ DECLARE actor uuid; BEGIN
  SELECT a.auth_user_id INTO actor FROM fauxlore.accounts a
    JOIN auth.users u ON u.id=a.auth_user_id
    JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
    WHERE a.role='admin' AND u.email_confirmed_at IS NOT NULL
      AND i.identity_data->>'email_verified'='true' LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'No verified administrator in snapshot'; END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
  IF public.fauxlore_api('auth/me','GET','{}'::jsonb,NULL)->'user'->>'role' <> 'admin' THEN
    RAISE EXCEPTION 'Administrator identity does not resolve';
  END IF;
  IF jsonb_typeof(public.fauxlore_api('admin/states','GET','{}'::jsonb,NULL)) <> 'array' THEN
    RAISE EXCEPTION 'Administrator states response is invalid';
  END IF;
END $$;
ROLLBACK;
