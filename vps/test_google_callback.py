import base64
import hashlib
import json
import time
import unittest
from unittest.mock import Mock, patch
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import rsa
from google.auth import crypt, jwt

from google_callback import TOKEN_ENDPOINT, complete_google_callback
from oauth_flow import OAuthFlowError, PendingGoogleLogins


class CallbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        public, private = rsa.newkeys(1024)
        cls.signer = crypt.RSASigner.from_string(private.save_pkcs1())
        cls.certs = json.dumps({'test-key': public.save_pkcs1().decode()}).encode()

    def setUp(self):
        self.pending = PendingGoogleLogins('client-id', 'https://sixiemeterre.ru/auth/google/callback')
        self.start = self.pending.begin()
        self.query = parse_qs(urlsplit(self.start.authorization_url).query)
        self.connection = Mock()
        self.user_id = uuid4()
        self.connection.execute.return_value.fetchone.return_value = (self.user_id,)

    def transport(self, *args, **kwargs):
        return type('Response', (), {'status': 200, 'data': self.certs})()

    def signed_token(self):
        now = int(time.time())
        return jwt.encode(self.signer, {'iss': 'https://accounts.google.com', 'aud': 'client-id',
            'sub': '123456', 'nonce': self.query['nonce'][0], 'email_verified': True,
            'iat': now - 1, 'exp': now + 300}, key_id='test-key').decode()

    def complete(self, browser_token=None):
        return complete_google_callback(pending=self.pending, state=self.query['state'][0],
            browser_token=browser_token or self.start.browser_token, code='test-code',
            client_secret='test-secret', google_transport=self.transport, connection=self.connection)

    @patch('google_callback.httpx.post')
    def test_exchanges_code_verifies_signed_identity_and_links_existing_user(self, post):
        post.return_value = Mock(status_code=200, json=lambda: {'id_token': self.signed_token()})
        self.assertEqual(self.complete(), self.user_id)
        args, kwargs = post.call_args
        self.assertEqual(args[0], TOKEN_ENDPOINT)
        self.assertFalse(kwargs['follow_redirects'])
        verifier = kwargs['data']['code_verifier']
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
        self.assertEqual(challenge, self.query['code_challenge'][0])
        self.assertEqual(self.connection.execute.call_args.args[1], ('123456',))
        with self.assertRaises(OAuthFlowError):
            self.complete()
        self.assertEqual(post.call_count, 1)

    @patch('google_callback.httpx.post')
    def test_wrong_browser_never_sends_token_request(self, post):
        with self.assertRaises(OAuthFlowError):
            self.complete('other-browser')
        post.assert_not_called()
        self.connection.execute.assert_not_called()

    @patch('google_callback.httpx.post')
    def test_failed_exchange_is_generic_and_cannot_be_replayed(self, post):
        post.return_value = Mock(status_code=400, json=lambda: {'error': 'test-secret'})
        with self.assertRaises(OAuthFlowError) as error:
            self.complete()
        self.assertNotIn('test-secret', str(error.exception))
        with self.assertRaises(OAuthFlowError):
            self.complete()
        self.assertEqual(post.call_count, 1)
        self.connection.execute.assert_not_called()


if __name__ == '__main__':
    unittest.main()
