"""Contract tests for the isolated guest-only preview."""

import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import preview


class PreviewTests(unittest.TestCase):
    def test_guest_wall_only_calls_fixed_read_action(self):
        with patch.object(preview, "read_wall", return_value=[]) as read:
            client = TestClient(preview.app)
            response = client.get("/wall/posts?filter=state&state_key=s%3A2&limit=6&offset=1")
            self.assertEqual(response.status_code, 200)
            read.assert_called_once_with(
                "list", {"filter": "state", "state_key": "s:2", "limit": 6, "offset": 1}
            )


    def test_guest_cannot_choose_a_write_action_or_unbounded_page(self):
        with patch.object(preview, "read_wall") as read:
            client = TestClient(preview.app)
            self.assertEqual(client.post("/wall/posts", json={"action": "delete"}).status_code, 405)
            self.assertEqual(client.get("/wall/posts?filter=delete").status_code, 422)
            self.assertEqual(client.get("/wall/posts?limit=1000").status_code, 422)
            self.assertEqual(client.get("/wall/delete").status_code, 404)
            read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
