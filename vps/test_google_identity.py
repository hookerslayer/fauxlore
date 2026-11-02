"""Cryptographic and account-link tests; all Google traffic is simulated."""

import json
import time
import unittest
from unittest.mock import Mock
from uuid import uuid4

import rsa
from google.auth import crypt, jwt

from google_identity import GoogleIdentity, IdentityError, find_linked_user, verify_google_identity


class GoogleIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.public, private = rsa.newkeys(1024)
        cls.signer = crypt.RSASigner.from_string(private.save_pkcs1())
        cls.certs = json.dumps({'test-key': cls.public.save_pkcs1().decode()}).encode()

    def transport(self, *args, **kwargs):
        return type('Response', (), {'status': 200, 'data': self.certs})()

    def token(self, **changes):
        now = int(time.time())
        payload = {'iss': 'https://accounts.google.com', 'aud': 'test-client',
                   'sub': '123456', 'nonce': 'nonce', 'email_verified': True,
                   'iat': now - 1, 'exp': now + 300}
        payload.update(changes)
        return jwt.encode(self.signer, payload, key_id='test-key').decode()

    def test_accepts_signed_token_for_expected_client_and_nonce(self):
        identity = verify_google_identity(self.token(), 'test-client', 'nonce', self.transport)
        self.assertEqual(identity, GoogleIdentity(subject='123456'))

    def test_verified_claims_for_new_account_are_retained(self):
        identity = verify_google_identity(self.token(email='player@example.invalid', name='Example'),
                                          'test-client', 'nonce', self.transport)
        self.assertEqual(identity, GoogleIdentity('123456', 'player@example.invalid', 'Example'))

    def test_rejects_wrong_audience_issuer_nonce_and_unverified_email(self):
        for token, nonce in ((self.token(aud='other'), 'nonce'),
                             (self.token(iss='https://wrong.example'), 'nonce'),
                             (self.token(), 'wrong'),
                             (self.token(email_verified=False), 'nonce'),
                             (self.token(exp=int(time.time()) - 60), 'nonce'),
                             (self.token(nonce='неверно'), 'nonce'),
                             (self.token(azp='other'), 'nonce')):
            with self.subTest(nonce=nonce), self.assertRaises(IdentityError):
                verify_google_identity(token, 'test-client', nonce, self.transport)

    def test_rejects_unverifiable_signature(self):
        token = self.token()
        bad_transport = lambda *args, **kwargs: type('Response', (), {'status': 200, 'data': b'{}'})()
        with self.assertRaises(IdentityError):
            verify_google_identity(token, 'test-client', 'nonce', bad_transport)
        _, attacker_key = rsa.newkeys(1024)
        attacker_signer = crypt.RSASigner.from_string(attacker_key.save_pkcs1())
        now = int(time.time())
        forged = jwt.encode(attacker_signer, {'iss': 'https://accounts.google.com',
            'aud': 'test-client', 'sub': '123456', 'nonce': 'nonce',
            'email_verified': True, 'iat': now - 1, 'exp': now + 300}, key_id='test-key').decode()
        with self.assertRaises(IdentityError):
            verify_google_identity(forged, 'test-client', 'nonce', self.transport)

    def test_links_only_one_existing_google_subject(self):
        user_id = uuid4()
        connection = Mock()
        connection.execute.return_value.fetchone.return_value = (user_id,)
        self.assertEqual(find_linked_user(connection, GoogleIdentity('123456')), user_id)
        self.assertEqual(connection.execute.call_args.args[1], ('123456',))
        for row in (None, (None,)):
            connection.execute.return_value.fetchone.return_value = row
            with self.assertRaises(IdentityError):
                find_linked_user(connection, GoogleIdentity('123456'))

    def test_new_identity_uses_verified_subject_and_never_links_by_email(self):
        user_id = uuid4()
        connection = Mock()
        connection.execute.return_value.fetchone.side_effect = [(None,), (user_id,)]
        identity = GoogleIdentity('new-subject', 'player@example.invalid', 'Example')
        self.assertEqual(find_linked_user(connection, identity), user_id)
        self.assertEqual(connection.execute.call_args.args[1], ('new-subject', 'player@example.invalid', 'Example'))
        connection.execute.return_value.fetchone.side_effect = [(None,), (None,)]
        with self.assertRaises(IdentityError):
            find_linked_user(connection, identity)


if __name__ == '__main__':
    unittest.main()
