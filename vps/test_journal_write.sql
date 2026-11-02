-- Verify journal authorization on the isolated snapshot, then roll back all changes.
BEGIN;
DO $$ DECLARE actor uuid; own_state integer; other_state integer; BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Write test requires the isolated preview database';
  END IF;
  SELECT a.auth_user_id, s.state_id INTO actor, own_state
  FROM fauxlore.accounts a JOIN fauxlore.account_states s ON s.account_id=a.id
  JOIN auth.users u ON u.id=a.auth_user_id
  JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
  WHERE a.role='player' AND u.email_confirmed_at IS NOT NULL
    AND i.identity_data->>'email_verified'='true' LIMIT 1;
  SELECT p.state_id INTO other_state FROM fauxlore.state_profiles p
  WHERE NOT EXISTS (SELECT 1 FROM fauxlore.account_states s JOIN fauxlore.accounts a ON a.id=s.account_id
                    WHERE a.auth_user_id=actor AND s.state_id=p.state_id) LIMIT 1;
  IF actor IS NULL OR own_state IS NULL OR other_state IS NULL THEN
    RAISE EXCEPTION 'Required test fixtures are missing';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
  PERFORM set_config('test.own_state',own_state::text,true);
  PERFORM set_config('test.other_state',other_state::text,true);
END $$;
SET LOCAL ROLE authenticated;
DO $$ DECLARE result jsonb; BEGIN
  result := public.state_journal_api('save_player',current_setting('test.own_state')::integer,'test-only-note');
  IF result->>'player_note' <> 'test-only-note' THEN RAISE EXCEPTION 'Own note was not saved'; END IF;
  BEGIN
    PERFORM public.state_journal_api('save_player',current_setting('test.other_state')::integer,'test-only-note');
    RAISE EXCEPTION 'Player could change another state journal';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.state_journal_api('save_admin',current_setting('test.own_state')::integer,'test-only-note');
    RAISE EXCEPTION 'Player could change an administrator note';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
ROLLBACK;

BEGIN;
DO $$ DECLARE actor uuid; other_state integer; BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Write test requires the isolated preview database';
  END IF;
  SELECT a.auth_user_id INTO actor FROM fauxlore.accounts a
  JOIN auth.users u ON u.id=a.auth_user_id
  JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
  WHERE a.role='admin' AND u.email_confirmed_at IS NOT NULL
    AND i.identity_data->>'email_verified'='true' LIMIT 1;
  SELECT p.state_id INTO other_state FROM fauxlore.state_profiles p
  WHERE NOT EXISTS (SELECT 1 FROM fauxlore.account_states s JOIN fauxlore.accounts a ON a.id=s.account_id
                    WHERE a.auth_user_id=actor AND s.state_id=p.state_id) LIMIT 1;
  IF actor IS NULL OR other_state IS NULL THEN RAISE EXCEPTION 'Required admin fixture is missing'; END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
  PERFORM set_config('test.other_state',other_state::text,true);
END $$;
SET LOCAL ROLE authenticated;
DO $$ DECLARE result jsonb; BEGIN
  result := public.state_journal_api('save_admin',current_setting('test.other_state')::integer,'test-admin-note');
  IF result->>'admin_note' <> 'test-admin-note' THEN RAISE EXCEPTION 'Admin note was not saved'; END IF;
  BEGIN
    PERFORM public.state_journal_api('save_player',current_setting('test.other_state')::integer,'test-only-note');
    RAISE EXCEPTION 'Administrator could change a player note without ownership';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
ROLLBACK;
