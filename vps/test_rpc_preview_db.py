"""Exercise isolated authenticated reads with short-lived, cleaned-up test sessions."""

import psycopg
from fastapi import FastAPI
from fastapi.testclient import TestClient

from auth_router import SESSION_COOKIE
from rpc_preview import create_rpc_router
from session_store import SessionStore

DSN = 'dbname=fauxlore_restore_filtered port=5433'


def rpc_connection():
    connection = psycopg.connect(DSN)
    connection.execute('SET ROLE fauxlore_rpc')
    connection.commit()
    return connection


def main():
    tokens = []
    with psycopg.connect(DSN) as setup:
        assert setup.execute('SELECT current_database()').fetchone()[0] == 'fauxlore_restore_filtered'
        users = {}
        for role in ('player', 'admin'):
            row = setup.execute('''SELECT a.auth_user_id FROM fauxlore.accounts a
                JOIN auth.users u ON u.id=a.auth_user_id
                JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
                WHERE a.role=%s AND u.email_confirmed_at IS NOT NULL
                  AND i.identity_data->>'email_verified'='true' LIMIT 1''', (role,)).fetchone()
            assert row is not None
            users[role] = row[0]
        assert not setup.execute("SELECT has_table_privilege('fauxlore_rpc','fauxlore.accounts','SELECT')").fetchone()[0]
        setup.execute('SET ROLE fauxlore_auth')
        store = SessionStore(setup, ttl_seconds=60)
        try:
            for role in ('player', 'admin'):
                tokens.append(store.create(users[role]))
            setup.commit()
            app = FastAPI()
            app.include_router(create_rpc_router(connection_factory=rpc_connection))
            client = TestClient(app, base_url='https://sixiemeterre.ru')
            assert client.get('/api/my/states').status_code == 401
            client.cookies.set(SESSION_COOKIE, tokens[0])
            player = client.get('/api/me', headers={'X-User-Id': str(users['admin'])})
            assert player.status_code == 200 and player.json()['user']['role'] == 'player'
            assert client.get('/api/my/states').status_code == 200
            assert client.get('/api/admin/states').status_code == 403
            assert client.post('/api/my/states').status_code == 405
            client.cookies.set(SESSION_COOKIE, tokens[1])
            admin = client.get('/api/me')
            assert admin.status_code == 200 and admin.json()['user']['role'] == 'admin'
            assert client.get('/api/admin/states').status_code == 200
            print('Real DB: session-bound player/admin permissions and write denial passed')
        finally:
            setup.rollback()
            for token in tokens:
                store.revoke(token)
            setup.commit()


if __name__ == '__main__':
    main()
