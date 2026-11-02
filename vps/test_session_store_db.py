"""Run as postgres against the isolated snapshot; all test writes roll back."""

import hashlib
import psycopg
from session_store import SessionStore


def main():
    with psycopg.connect('dbname=fauxlore_restore_filtered port=5433') as connection:
        try:
            assert connection.execute('SELECT current_database()').fetchone()[0] == 'fauxlore_restore_filtered'
            user_id = connection.execute(
                'SELECT auth_user_id FROM fauxlore.accounts WHERE auth_user_id IS NOT NULL LIMIT 1'
            ).fetchone()[0]
            assert not connection.execute(
                "SELECT has_schema_privilege('anon', 'fauxlore_vps_preview', 'USAGE')"
            ).fetchone()[0]
            store = SessionStore(connection, ttl_seconds=60)
            token = store.create(user_id)
            assert store.resolve(token) == user_id
            connection.execute("UPDATE fauxlore_vps_preview.sessions SET expires_at=now()-interval '1 second' WHERE token_hash=%s",
                               (hashlib.sha256(token.encode('ascii')).digest(),))
            assert store.resolve(token) is None
            second_token = store.create(user_id)
            assert store.resolve(second_token) == user_id
            store.revoke(second_token)
            assert store.resolve(second_token) is None
            print('Session create, expiry, logout and guest isolation: passed')
        finally:
            connection.rollback()


if __name__ == '__main__':
    main()
