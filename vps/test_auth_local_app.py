import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
from fastapi.testclient import TestClient
from auth_local_app import create_app

class LocalAuthTests(unittest.TestCase):
    def test_local_callback_and_secret_remain_server_side(self):
        with tempfile.TemporaryDirectory() as temp:
            Path(temp, 'google_client_secret').write_text('example-secret', encoding='utf-8')
            with patch.dict(os.environ, {'FAUXLORE_GOOGLE_CLIENT_ID':'example-client',
                                        'CREDENTIALS_DIRECTORY':temp}, clear=True):
                client = TestClient(create_app(), base_url='http://localhost:18093')
                response = client.get('/auth/google/start', follow_redirects=False)
                self.assertEqual(response.status_code, 302)
                params = parse_qs(urlsplit(response.headers['location']).query)
                self.assertEqual(params['redirect_uri'], ['http://localhost:18093/auth/google/callback'])
                self.assertNotIn('example-secret', response.headers['location'])
                self.assertEqual(client.post('/auth/logout', headers={'Origin':'http://evil.example'}).status_code, 403)

if __name__ == '__main__': unittest.main()
