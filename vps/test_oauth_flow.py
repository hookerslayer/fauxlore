import base64
import hashlib
import unittest
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import parse_qs, urlsplit

from oauth_flow import OAuthFlowError, PendingGoogleLogins


class OAuthFlowTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000
        self.flow = PendingGoogleLogins('client-id', 'https://sixiemeterre.ru/auth/google/callback',
                                        ttl=60, clock=lambda: self.now)

    def start(self):
        start = self.flow.begin()
        url = urlsplit(start.authorization_url)
        self.assertEqual((url.scheme, url.netloc, url.path),
                         ('https', 'accounts.google.com', '/o/oauth2/v2/auth'))
        return start, parse_qs(url.query, strict_parsing=True)

    def test_valid_state_binds_browser_nonce_and_pkce(self):
        start, query = self.start()
        state = query['state'][0]
        with self.assertRaises(OAuthFlowError):
            self.flow.consume(state, 'wrong-browser')
        secrets = self.flow.consume(state, start.browser_token)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(secrets.code_verifier.encode()).digest()).rstrip(b'=').decode()
        self.assertEqual(query['code_challenge'], [challenge])
        self.assertEqual(query['code_challenge_method'], ['S256'])
        self.assertEqual(query['nonce'], [secrets.nonce])
        with self.assertRaises(OAuthFlowError):
            self.flow.consume(state, start.browser_token)

    def test_expired_and_malformed_state_rejected(self):
        start, query = self.start()
        self.now += 60
        with self.assertRaises(OAuthFlowError):
            self.flow.consume(query['state'][0], start.browser_token)
        for state in ('', 'неверно', 'x' * 257):
            with self.assertRaises(OAuthFlowError):
                self.flow.consume(state, start.browser_token)

    def test_only_one_concurrent_callback_can_consume_state(self):
        start, query = self.start()
        def consume():
            try:
                self.flow.consume(query['state'][0], start.browser_token)
                return True
            except OAuthFlowError:
                return False
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(sum(pool.map(lambda _: consume(), range(8))), 1)

    def test_https_and_capacity_are_enforced(self):
        with self.assertRaises(ValueError):
            PendingGoogleLogins('client-id', 'http://sixiemeterre.ru/callback')
        flow = PendingGoogleLogins('client-id', 'https://sixiemeterre.ru/callback', capacity=1)
        flow.begin()
        with self.assertRaises(OAuthFlowError):
            flow.begin()

    def test_http_is_allowed_only_for_explicit_exact_local_test(self):
        local = 'http://localhost:18093/auth/google/callback'
        with self.assertRaises(ValueError):
            PendingGoogleLogins('client-id', local)
        flow = PendingGoogleLogins('client-id', local, allow_local_test=True)
        self.assertIn('localhost%3A18093', flow.begin().authorization_url)
        for invalid in ('http://localhost:18094/auth/google/callback',
                        'http://127.0.0.1:18093/auth/google/callback',
                        'http://evil.example:18093/auth/google/callback'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                PendingGoogleLogins('client-id', invalid, allow_local_test=True)


if __name__ == '__main__':
    unittest.main()
