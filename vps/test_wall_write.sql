-- Test guest, player and administrator wall authorization; all writes roll back.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Wall write test requires the isolated preview database';
  END IF;
  PERFORM set_config('request.jwt.claim.sub','',true);
END $$;
SET LOCAL ROLE anon;
DO $$ BEGIN
  BEGIN
    PERFORM public.wall_api('react','{"post_id":1,"reaction":"like"}'::jsonb);
    RAISE EXCEPTION 'Guest could add a reaction';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
ROLLBACK;

BEGIN;
DO $$ DECLARE actor uuid; post_id bigint; BEGIN
  SELECT a.auth_user_id INTO actor FROM fauxlore.accounts a
  JOIN auth.users u ON u.id=a.auth_user_id
  JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
  WHERE a.role='player' AND u.email_confirmed_at IS NOT NULL
    AND i.identity_data->>'email_verified'='true' LIMIT 1;
  SELECT id INTO post_id FROM fauxlore.wall_posts ORDER BY id LIMIT 1;
  IF actor IS NULL OR post_id IS NULL THEN RAISE EXCEPTION 'Wall test fixtures are missing'; END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
  PERFORM set_config('test.wall_post_id',post_id::text,true);
END $$;
SET LOCAL ROLE authenticated;
DO $$ DECLARE result jsonb; pid bigint := current_setting('test.wall_post_id')::bigint; BEGIN
  result := public.wall_api('react',jsonb_build_object('post_id',pid,'reaction','like'));
  IF result->>'ok' <> 'true' THEN RAISE EXCEPTION 'Player reaction failed'; END IF;
  result := public.wall_api('comment',jsonb_build_object('post_id',pid,'body','test-only comment'));
  IF result->>'id' IS NULL THEN RAISE EXCEPTION 'Player comment failed'; END IF;
  BEGIN
    PERFORM public.wall_api('delete',jsonb_build_object('post_id',pid));
    RAISE EXCEPTION 'Player could delete a post';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.wall_api('set_posting','{"enabled":false}'::jsonb);
    RAISE EXCEPTION 'Player could change posting settings';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
ROLLBACK;

BEGIN;
DO $$ DECLARE actor uuid; BEGIN
  SELECT a.auth_user_id INTO actor FROM fauxlore.accounts a
  JOIN auth.users u ON u.id=a.auth_user_id
  JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
  WHERE a.role='admin' AND u.email_confirmed_at IS NOT NULL
    AND i.identity_data->>'email_verified'='true' LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'Admin wall fixture is missing'; END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
END $$;
SET LOCAL ROLE authenticated;
DO $$ DECLARE result jsonb; BEGIN
  result := public.wall_api('set_posting','{"enabled":false}'::jsonb);
  IF result->'player_posting_enabled' <> 'false'::jsonb THEN
    RAISE EXCEPTION 'Admin posting setting failed';
  END IF;
END $$;
ROLLBACK;
