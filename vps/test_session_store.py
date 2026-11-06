import hashlib
import unittest
from unittest.mock import Mock
from uuid import uuid4

from session_store import SessionStore


class SessionStoreTests(unittest.TestCase):
    def setUp(self):
        self.connection = Mock()
        self.user_id = uuid4()
        self.store = SessionStore(self.connection)

    def test_create_stores_only_digest_and_resolve_checks_expiry(self):
        token = self.store.create(self.user_id)
        sql, params = self.connection.execute.call_args.args
        self.assertIn('INSERT INTO', sql)
        self.assertEqual(params, (hashlib.sha256(token.encode('ascii')).digest(), self.user_id, 43200))
        self.connection.execute.return_value.fetchone.return_value = (self.user_id,)
        self.assertEqual(self.store.resolve(token), self.user_id)
        sql, params = self.connection.execute.call_args.args
        self.assertIn('fauxlore_vps_preview.resolve_session', sql)
        self.assertEqual(params, (hashlib.sha256(token.encode('ascii')).digest(),))

    def test_missing_expired_or_malformed_token_has_no_session(self):
        self.connection.execute.return_value.fetchone.return_value = None
        self.assertIsNone(self.store.resolve('a' * 43))
        self.connection.reset_mock()
        for token in ('', 'not valid', 'я' * 43, 'x' * 44, None):
            self.assertIsNone(self.store.resolve(token))
        self.connection.execute.assert_not_called()

    def test_logout_deletes_digest_and_rejects_invalid(self):
        token = self.store.create(self.user_id)
        self.connection.reset_mock()
        self.store.revoke(token)
        sql, params = self.connection.execute.call_args.args
        self.assertIn('DELETE FROM', sql)
        self.assertEqual(params, (hashlib.sha256(token.encode('ascii')).digest(),))
        self.connection.reset_mock()
        self.store.revoke('invalid')
        self.connection.execute.assert_not_called()

    def test_touch_extends_only_valid_token_and_uses_configured_idle_ttl(self):
        token = self.store.create(self.user_id)
        self.connection.reset_mock()
        self.connection.execute.return_value.fetchone.return_value = (True,)
        self.connection.execute.side_effect = None
        self.assertTrue(self.store.touch(token))
        sql, params = self.connection.execute.call_args.args
        self.assertIn('fauxlore_vps_preview.renew_session', sql)
        self.assertEqual(params, (hashlib.sha256(token.encode('ascii')).digest(), 43200))
        self.connection.reset_mock()
        self.assertFalse(self.store.touch('invalid'))
        self.connection.execute.assert_not_called()

    def test_rejects_unverified_uuid_type_and_bad_lifetime(self):
        with self.assertRaises(ValueError):
            self.store.create(str(self.user_id))
        for ttl in (0, -1, 43201, True):
            with self.assertRaises(ValueError):
                SessionStore(self.connection, ttl)
        self.connection.execute.assert_not_called()


if __name__ == '__main__':
    unittest.main()
