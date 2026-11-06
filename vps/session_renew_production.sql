-- Production-миграция продления сессий (применена 6 ноября 2026).
-- Причина: утренний деплой session_store.py начал вызывать
-- fauxlore_vps_preview.renew_session, но функция существовала только в
-- тестовом SQL (vps/session_status_test.sql) с защитой от запуска вне
-- fauxlore_restore_filtered. В production её не было, и все запросы с
-- валидной сессией падали с 500 (psycopg UndefinedFunction).
--
-- Защита: скрипт отказывается работать с любой другой базой.
-- Откат: DROP FUNCTION fauxlore_vps_preview.renew_session(bytea,integer);
--        ALTER TABLE fauxlore_vps_preview.sessions DROP COLUMN created_at;

BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_production_candidate' THEN
    RAISE EXCEPTION 'Refusing to change session schema outside production candidate';
  END IF;
END $$;

ALTER TABLE fauxlore_vps_preview.sessions
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

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

REVOKE ALL ON FUNCTION fauxlore_vps_preview.renew_session(bytea,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.renew_session(bytea,integer) TO fauxlore_auth,fauxlore_rpc;

COMMIT;
