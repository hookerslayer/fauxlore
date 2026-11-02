import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from auth_app import create_app


class AuthAppTests(unittest.TestCase):
    def test_missing_configuration_fails_closed(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(RuntimeError):
                create_app()

    def test_isolated_start_uses_credential_without_exposing_it(self):
        with tempfile.TemporaryDirectory() as temp:
            Path(temp, 'google_client_secret').write_text('example-secret', encoding='utf-8')
            with patch.dict(os.environ, {'FAUXLORE_GOOGLE_CLIENT_ID': 'example-client',
                                        'CREDENTIALS_DIRECTORY': temp}, clear=True):
                client = TestClient(create_app(), base_url='https://sixiemeterre.ru')
                response = client.get('/auth/google/start', follow_redirects=False)
                self.assertEqual(response.status_code, 302)
                self.assertTrue(response.headers['location'].startswith('https://accounts.google.com/'))
                self.assertNotIn('example-secret', response.headers['location'])
                self.assertNotIn('example-secret', response.text)
                self.assertEqual(client.get('/docs').status_code, 404)


if __name__ == '__main__':
    unittest.main()
