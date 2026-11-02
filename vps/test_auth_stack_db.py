"""Local test of OAuth/session code against the isolated database. No Google calls."""

import json
import time
from contextlib import nullcontext
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import psycopg
import rsa
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.auth import crypt, jwt

from auth_router import SESSION_COOKIE, create_auth_router
from oauth_flow import PendingGoogleLogins
from session_store import SessionStore
from psycopg.types.json import Jsonb


def main():
    with psycopg.connect('dbname=fauxlore_restore_filtered port=5433') as connection:
        try:
            assert connection.execute('SELECT current_database()').fetchone()[0] == 'fauxlore_restore_filtered'
            subject = connection.execute('''SELECT i.identity_data->>'sub' FROM fauxlore.accounts a
                JOIN auth.users u ON u.id=a.auth_user_id
                JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
                WHERE u.email_confirmed_at IS NOT NULL AND i.identity_data->>'email_verified'='true'
                  AND coalesce(i.identity_data->>'sub','') <> '' LIMIT 1''').fetchone()[0]
            connection.execute('SET LOCAL ROLE fauxlore_auth')
            assert connection.execute('SELECT current_user').fetchone()[0] == 'fauxlore_auth'
            public, private = rsa.newkeys(1024)
            signer = crypt.RSASigner.from_string(private.save_pkcs1())
            certs = json.dumps({'test-key': public.save_pkcs1().decode()}).encode()
            def transport(*args, **kwargs):
                return type('Response', (), {'status': 200, 'data': certs})()
            pending = PendingGoogleLogins('test-client', 'https://sixiemeterre.ru/auth/google/callback')
            app = FastAPI()
            app.include_router(create_auth_router(
                pending=pending, client_secret='test-secret', google_transport=transport,
                connection_factory=lambda: nullcontext(connection), origin='https://sixiemeterre.ru'))
            client = TestClient(app, base_url='https://sixiemeterre.ru')
            start = client.get('/auth/google/start', follow_redirects=False)
            query = parse_qs(urlsplit(start.headers['location']).query)
            now = int(time.time())
            token = jwt.encode(signer, {'iss': 'https://accounts.google.com', 'aud': 'test-client',
                'sub': subject, 'nonce': query['nonce'][0], 'email_verified': True,
                'iat': now-1, 'exp': now+300}, key_id='test-key').decode()
            with patch('google_callback.httpx.post', return_value=Mock(status_code=200, json=lambda: {'id_token': token})):
                callback = client.get('/auth/google/callback', params={'state': query['state'][0], 'code': 'test-code'},
                                      follow_redirects=False)
                assert callback.status_code == 303 and callback.headers['location'] == '/auth/complete?status=ok'
            assert client.get('/auth/session').json() == {'authenticated': True}
            assert client.post('/auth/logout', headers={'Origin': 'https://evil.example'}).status_code == 403
            assert client.post('/auth/logout', headers={'Origin': 'https://sixiemeterre.ru'}).status_code == 200
            assert client.get('/auth/session').json() == {'authenticated': False}
            start = client.get('/auth/google/start', follow_redirects=False)
            query = parse_qs(urlsplit(start.headers['location']).query)
            synthetic = uuid4().hex
            new_token = jwt.encode(signer, {'iss': 'https://accounts.google.com', 'aud': 'test-client',
                'sub': 'synthetic-' + synthetic, 'email': synthetic + '@example.invalid', 'name': 'Test Player',
                'nonce': query['nonce'][0], 'email_verified': True,
                'iat': now-1, 'exp': now+300}, key_id='test-key').decode()
            with patch('google_callback.httpx.post', return_value=Mock(status_code=200, json=lambda: {'id_token': new_token})):
                callback = client.get('/auth/google/callback', params={'state': query['state'][0], 'code': 'test-code'},
                                      follow_redirects=False)
            assert callback.headers['location'] == '/auth/complete?status=ok'
            assert client.get('/auth/session').json() == {'authenticated': True}
            user_id = SessionStore(connection).resolve(client.cookies.get(SESSION_COOKIE))
            assert user_id is not None
            connection.execute('SET LOCAL ROLE authenticated')
            connection.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (str(user_id),))
            profile = connection.execute("SELECT public.fauxlore_api('auth/me','GET',%s,NULL)", (Jsonb({}),)).fetchone()[0]
            assert profile['user']['role'] == 'player' and profile['user']['nickname'] == 'Test Player'
            connection.execute('SET LOCAL ROLE fauxlore_auth')
            assert client.post('/auth/logout', headers={'Origin': 'https://sixiemeterre.ru'}).status_code == 200
            print('Signed test tokens: existing and new users, database role, session and logout passed')
        finally:
            connection.rollback()


if __name__ == '__main__':
    main()
