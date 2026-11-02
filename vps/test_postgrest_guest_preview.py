from unittest import TestCase
from unittest.mock import patch
from fastapi.testclient import TestClient
from postgrest_guest_preview import app

class GuestPreviewTests(TestCase):
    def setUp(self):
        self.client = TestClient(app)

    def test_rejects_writes_and_unknown_methods(self):
        with patch('postgrest_guest_preview.urlopen') as upstream:
            for name, data in [
                ('fauxlore_api', {'path': 'admin/turn/advance', 'method': 'POST'}),
                ('fauxlore_api', {'path': 'map', 'method': 'PATCH'}),
                ('wall_api', {'action': 'create', 'payload': {}}),
                ('military_api', {'action': 'snapshot'}),
            ]:
                assert self.client.post('/api/rpc/' + name, json=data).status_code == 403
            upstream.assert_not_called()

    def test_guest_request_never_passes_cookies_or_bearer(self):
        with patch('postgrest_guest_preview.urlopen') as upstream:
            response = upstream.return_value.__enter__.return_value
            response.status = 200
            response.read.return_value = b'{}'
            result = self.client.post('/api/rpc/fauxlore_api',
                json={'path': 'health', 'method': 'GET', 'body': {}, 'request_id': None},
                headers={'Cookie': 'private=secret', 'Authorization': 'Bearer forged'})
            assert result.status_code == 200
            request = upstream.call_args.args[0]
            assert request.get_header('Cookie') is None
            assert request.get_header('Authorization') is None
