import json
import unittest
from contextlib import nullcontext
from unittest.mock import Mock
from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient
from auth_router import SESSION_COOKIE
from postgrest_bridge import create_bridge


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.user = uuid4()
        self.connection = Mock()
        self.connection.execute.return_value.fetchone.return_value = (self.user,)
        self.calls = []
        def send(name, data, token):
            self.calls.append((name, data, token))
            return 200, b'{"ok":true}'
        app = FastAPI()
        app.include_router(create_bridge(connection_factory=lambda: nullcontext(self.connection),
                                         secret=b'x'*48, transport=send))
        self.client = TestClient(app, base_url='https://sixiemeterre.ru')
        self.headers = {'Origin': 'https://sixiemeterre.ru'}

    def test_rejects_unknown_and_cross_origin(self):
        assert self.client.post('/api/rpc/fauxlore_api', json={}).status_code == 403
        assert self.client.post('/api/rpc/projection_source_api', json={}, headers=self.headers).status_code == 404
        assert self.client.post('/api/rpc/fauxlore_api', content='{"x":NaN}', headers={**self.headers, 'Content-Type': 'application/json'}).status_code == 422
        assert not self.calls

    def test_guest_and_session_token_never_exposed(self):
        payload = {'path': 'health', 'method': 'GET', 'body': {}, 'request_id': None}
        response = self.client.post('/api/rpc/fauxlore_api', json=payload, headers={**self.headers, 'Authorization': 'Bearer forged'})
        assert response.json() == {'ok': True} and self.calls[-1][2] is None
        self.client.cookies.set(SESSION_COOKIE, 'a'*43)
        response = self.client.post('/api/rpc/fauxlore_api', json=payload, headers=self.headers)
        assert response.status_code == 200 and self.calls[-1][2] is not None
        assert self.calls[-1][2] not in response.text
        assert response.headers['cache-control'] == 'no-store'

if __name__ == '__main__':
    unittest.main()
