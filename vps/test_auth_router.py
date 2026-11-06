import unittest
import json
import time
from contextlib import nullcontext
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import rsa
from fastapi import FastAPI
from fastapi.testclient import TestClient
from google.auth import crypt, jwt

import auth_router
from oauth_flow import OAuthFlowError, PendingGoogleLogins


class AuthRouterTests(unittest.TestCase):
    def setUp(self):
        self.connection = Mock()
        self.pending = PendingGoogleLogins('test-client', 'https://sixiemeterre.ru/auth/google/callback')
        app = FastAPI()
        app.include_router(auth_router.create_auth_router(
            pending=self.pending, client_secret='server-secret', google_transport=Mock(),
            connection_factory=lambda: nullcontext(self.connection), origin='https://sixiemeterre.ru'))
        self.client = TestClient(app, base_url='https://sixiemeterre.ru')

    def start(self):
        response = self.client.get('/auth/google/start', follow_redirects=False)
        self.assertEqual(response.status_code, 302)
        cookie = response.headers['set-cookie'].lower()
        self.assertIn('secure', cookie)
        self.assertIn('httponly', cookie)
        self.assertIn('samesite=lax', cookie)
        return parse_qs(urlsplit(response.headers['location']).query)['state'][0]

    @patch('auth_router.SessionStore')
    @patch('auth_router.complete_google_callback')
    def test_success_sets_secure_session_without_exposing_user_id(self, complete, store_class):
        state = self.start()
        user_id = uuid4()
        complete.return_value = user_id
        store = store_class.return_value
        store.create.return_value = 'x' * 43
        store.ttl_seconds = 3600
        response = self.client.get('/auth/google/callback', params={'state': state, 'code': 'code'},
                                   follow_redirects=False)
        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers['location'], '/auth/complete?status=ok')
        self.assertNotIn(str(user_id), response.text)
        session_cookie = next(c for c in response.headers.get_list('set-cookie')
                              if c.startswith(auth_router.SESSION_COOKIE + '='))
        self.assertIn('HttpOnly', session_cookie)
        self.assertIn('Secure', session_cookie)
        self.assertIn('SameSite=lax', session_cookie)
        self.assertEqual(response.headers['cache-control'], 'no-store')
        self.assertTrue(complete.call_args.kwargs['browser_token'])
        store.create.assert_called_once_with(user_id)

    @patch('auth_router.SessionStore')
    @patch('auth_router.complete_google_callback', side_effect=OAuthFlowError('failed'))
    def test_failed_callback_does_not_create_session(self, complete, store_class):
        state = self.start()
        response = self.client.get('/auth/google/callback', params={'state': state, 'code': 'code'},
                                   follow_redirects=False)
        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers['location'], '/auth/complete?status=failed')
        self.assertFalse(any(c.startswith(auth_router.SESSION_COOKIE + '=')
                             for c in response.headers.get_list('set-cookie')))
        store_class.assert_not_called()

    @patch('auth_router.SessionStore')
    def test_logout_rejects_cross_origin_and_requires_origin(self, store_class):
        self.assertEqual(self.client.post('/auth/logout').status_code, 403)
        self.assertEqual(self.client.post('/auth/logout', headers={'Origin': 'https://evil.example'}).status_code, 403)
        store_class.assert_not_called()
        response = self.client.post('/auth/logout', headers={'Origin': 'https://sixiemeterre.ru',
                                                             'Sec-Fetch-Site': 'same-origin'})
        self.assertEqual(response.status_code, 200)
        self.assertIn('Max-Age=0', response.headers['set-cookie'])
        store_class.return_value.revoke.assert_called_once()

    @patch('auth_router.SessionStore')
    def test_authenticated_session_status_renews_cookie(self, store_class):
        token = 'x' * 43
        self.client.cookies.set(auth_router.SESSION_COOKIE, token)
        store_class.return_value.resolve.return_value = uuid4()
        store_class.return_value.touch.return_value = True
        response = self.client.get('/auth/session')
        self.assertEqual(response.json(), {'authenticated': True})
        self.assertIn(f'{auth_router.SESSION_COOKIE}={token}', response.headers['set-cookie'])
        self.assertIn('Max-Age=43200', response.headers['set-cookie'])
        self.assertIn('HttpOnly', response.headers['set-cookie'])
        store_class.return_value.resolve.assert_called_once_with(token)
        store_class.return_value.touch.assert_called_once_with(token)

    @patch('auth_router.complete_google_callback')
    def test_cancelled_google_login_does_not_exchange_or_create_session(self, complete):
        state = self.start()
        response = self.client.get('/auth/google/callback', params={'state': state, 'error': 'access_denied'},
                                   follow_redirects=False)
        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers['location'], '/auth/complete?status=failed')
        self.assertFalse(any(c.startswith(auth_router.SESSION_COOKIE + '=')
                             for c in response.headers.get_list('set-cookie')))
        complete.assert_not_called()

    @patch('google_callback.httpx.post')
    def test_end_to_end_with_signed_google_response_and_session(self, post):
        public, private = rsa.newkeys(1024)
        signer = crypt.RSASigner.from_string(private.save_pkcs1())
        certs = json.dumps({'test-key': public.save_pkcs1().decode()}).encode()
        def transport(*args, **kwargs):
            return type('Response', (), {'status': 200, 'data': certs})()
        user_id = uuid4()
        sessions = {}
        connection = Mock()
        def execute(query, params=()):
            result = Mock()
            if 'lookup_google_user' in query:
                result.fetchone.return_value = (user_id,)
            elif 'INSERT INTO fauxlore_vps_preview.sessions' in query:
                sessions[params[0]] = params[1]
            elif 'resolve_session' in query:
                match = sessions.get(params[0])
                result.fetchone.return_value = (match,) if match else None
            elif 'renew_session' in query:
                result.fetchone.return_value = (params[0] in sessions,)
            elif 'DELETE FROM fauxlore_vps_preview.sessions' in query:
                sessions.pop(params[0], None)
            else:
                raise AssertionError('Unexpected database operation')
            return result
        connection.execute.side_effect = execute
        pending = PendingGoogleLogins('test-client', 'https://sixiemeterre.ru/auth/google/callback')
        app = FastAPI()
        app.include_router(auth_router.create_auth_router(
            pending=pending, client_secret='server-secret', google_transport=transport,
            connection_factory=lambda: nullcontext(connection), origin='https://sixiemeterre.ru'))
        client = TestClient(app, base_url='https://sixiemeterre.ru')
        start = client.get('/auth/google/start', follow_redirects=False)
        params = parse_qs(urlsplit(start.headers['location']).query)
        now = int(time.time())
        token = jwt.encode(signer, {'iss': 'https://accounts.google.com', 'aud': 'test-client',
            'sub': 'google-user', 'nonce': params['nonce'][0], 'email_verified': True,
            'iat': now - 1, 'exp': now + 300}, key_id='test-key').decode()
        post.return_value = Mock(status_code=200, json=lambda: {'id_token': token})
        callback = client.get('/auth/google/callback', params={'state': params['state'][0], 'code': 'code'},
                              follow_redirects=False)
        self.assertEqual(callback.status_code, 303)
        self.assertEqual(callback.headers['location'], '/auth/complete?status=ok')
        self.assertEqual(client.get('/auth/session').json(), {'authenticated': True})
        replay = client.get('/auth/google/callback', params={'state': params['state'][0], 'code': 'code'},
                            follow_redirects=False)
        self.assertEqual(replay.headers['location'], '/auth/complete?status=failed')
        self.assertEqual(post.call_count, 1)
        self.assertEqual(client.post('/auth/logout', headers={'Origin': 'https://evil.example'}).status_code, 403)
        self.assertEqual(client.post('/auth/logout', headers={'Origin': 'https://sixiemeterre.ru'}).status_code, 200)
        self.assertEqual(client.get('/auth/session').json(), {'authenticated': False})


if __name__ == '__main__':
    unittest.main()
