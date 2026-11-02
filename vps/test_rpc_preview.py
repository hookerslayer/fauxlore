import unittest
from contextlib import nullcontext
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from unittest.mock import Mock, patch
from uuid import uuid4

import psycopg
from fastapi import FastAPI
from fastapi.testclient import TestClient

from auth_router import SESSION_COOKIE
from rpc_preview import create_rpc_router
from province_projection import PROJECTION_SLOTS


class RpcPreviewTests(unittest.TestCase):
    def setUp(self):
        self.user_id = uuid4()
        self.connection = Mock()
        self.connection.transaction.return_value = nullcontext()
        self.calls = []
        def execute(sql, params=()):
            self.calls.append((sql, params))
            result = Mock()
            if 'resolve_session' in sql:
                result.fetchone.return_value = (self.user_id,)
            elif 'public.fauxlore_api' in sql:
                if params[0] == 'admin/states':
                    raise psycopg.errors.InsufficientPrivilege('denied')
                result.fetchone.return_value = ({'ok': True},)
            elif 'public.state_journal_api' in sql:
                state_id = params[1] if len(params) == 3 else params[0]
                if state_id == 999:
                    raise psycopg.errors.InsufficientPrivilege('denied')
                result.fetchone.return_value = ({'state_id': state_id},)
            elif 'public.wall_api' in sql:
                if params[0] in ('delete', 'set_posting'):
                    raise psycopg.errors.InsufficientPrivilege('denied')
                result.fetchone.return_value = ({'ok': True},)
            return result
        self.connection.execute.side_effect = execute
        app = FastAPI()
        app.include_router(create_rpc_router(connection_factory=lambda: nullcontext(self.connection)))
        self.client = TestClient(app, base_url='https://sixiemeterre.ru')

    def test_only_server_session_sets_identity(self):
        self.client.cookies.set(SESSION_COOKIE, 'a' * 43)
        response = self.client.get('/api/my/states?user_id=attacker', headers={'X-User-Id': 'attacker'})
        self.assertEqual(response.status_code, 200)
        claim = next(params for sql, params in self.calls if 'set_config' in sql)
        self.assertEqual(claim, (str(self.user_id),))
        rpc = next(params for sql, params in self.calls if 'public.fauxlore_api' in sql)
        self.assertEqual(rpc[0], 'my/states')
        self.assertEqual(response.headers['cache-control'], 'no-store')
        self.assertEqual(self.calls[0][0], 'SET TRANSACTION READ ONLY')

    def test_requires_session_and_rejects_writes(self):
        self.assertEqual(self.client.get('/api/my/states').status_code, 401)
        self.assertEqual(self.client.post('/api/my/states').status_code, 405)
        self.assertEqual(self.client.get('/api/arbitrary').status_code, 404)
        self.assertFalse(any('set_config' in sql for sql, _ in self.calls))

    def test_database_denial_is_forbidden(self):
        self.client.cookies.set(SESSION_COOKIE, 'a' * 43)
        self.assertEqual(self.client.get('/api/admin/states').status_code, 403)

    def test_journal_reads_are_parameterized_and_authorized(self):
        self.client.cookies.set(SESSION_COOKIE, 'a' * 43)
        self.assertEqual(self.client.get('/api/states/2/journal').json(), {'state_id': 2})
        self.assertEqual(self.client.get('/api/states/999/journal').status_code, 403)
        self.assertEqual(self.client.get('/api/states/0/journal').status_code, 422)
        query, params = next((sql, params) for sql, params in self.calls if 'state_journal_api' in sql)
        self.assertIn("'snapshot'", query)
        self.assertEqual(params, (2,))

    def test_journal_write_requires_same_origin_and_server_session(self):
        self.client.cookies.set(SESSION_COOKIE, 'a' * 43)
        url = '/api/states/2/journal/player'
        self.assertEqual(self.client.post(url, json={'note': 'test'}).status_code, 403)
        self.assertEqual(self.client.post(url, json={'note': 'test'},
                         headers={'Origin': 'https://evil.example'}).status_code, 403)
        self.assertEqual(self.client.post(url, json={'note': 'test', 'role': 'admin'},
                         headers={'Origin': 'https://sixiemeterre.ru'}).status_code, 422)
        self.assertFalse(any('state_journal_api' in sql for sql, _ in self.calls))
        result = self.client.post(url, json={'note': 'test'},
                                  headers={'Origin': 'https://sixiemeterre.ru',
                                           'Sec-Fetch-Site': 'same-origin'})
        self.assertEqual(result.status_code, 200)
        query, params = next((sql, params) for sql, params in self.calls if 'state_journal_api' in sql)
        self.assertEqual(params, ('save_player', 2, 'test'))
        self.assertEqual(self.client.post('/api/states/999/journal/player', json={'note': 'test'},
                         headers={'Origin': 'https://sixiemeterre.ru'}).status_code, 403)
        self.assertEqual(self.client.post('/api/states/2/journal/other', json={'note': 'test'},
                         headers={'Origin': 'https://sixiemeterre.ru'}).status_code, 422)
        self.assertEqual(self.client.post('/api/states/2/journal/admin', json={'note': 'test'},
                         headers={'Origin': 'https://sixiemeterre.ru'}).status_code, 200)
        self.assertEqual(self.calls[-1][1], ('save_admin', 2, 'test'))

    def test_wall_reads_and_writes_enforce_validation_and_origin(self):
        self.client.cookies.set(SESSION_COOKIE, 'a' * 43)
        same = {'Origin': 'https://sixiemeterre.ru'}
        self.assertEqual(self.client.get('/api/wall/list?limit=6').status_code, 200)
        self.assertEqual(self.client.post('/api/wall/react', json={'post_id': 1, 'reaction': 'like'}).status_code, 403)
        self.assertEqual(self.client.post('/api/wall/react', json={'post_id': 1, 'reaction': 'like', 'role': 'admin'},
                         headers=same).status_code, 422)
        self.assertEqual(self.client.post('/api/wall/react', json={'post_id': -1, 'reaction': 'like'},
                         headers=same).status_code, 422)
        self.assertEqual(self.client.post('/api/wall/react', content='{',
                         headers={**same, 'Content-Type': 'application/json'}).status_code, 400)
        self.assertEqual(self.client.post('/api/wall/react', content='{}', headers={**same,
                         'Content-Type': 'application/json', 'Content-Length': '6000001'}).status_code, 413)
        self.assertEqual(self.client.post('/api/wall/react', json={'post_id': 1, 'reaction': 'like'},
                         headers=same).status_code, 200)
        action, payload = self.calls[-1][1]
        self.assertEqual(action, 'react')
        self.assertEqual(payload.obj, {'post_id': 1, 'reaction': 'like'})
        self.assertEqual(self.client.post('/api/wall/delete', json={'post_id': 1}, headers=same).status_code, 403)
        self.assertEqual(self.client.post('/api/wall/verdict', json={}, headers=same).status_code, 422)

    @patch('rpc_preview.run_province_worker')
    @patch('rpc_preview.build_province_snapshot')
    def test_projection_uses_server_snapshot_and_rejects_forged_inputs(self, build, worker):
        self.client.cookies.set(SESSION_COOKIE, 'a' * 43)
        same = {'Origin': 'https://sixiemeterre.ru'}
        build.return_value = {'server': 'snapshot'}
        worker.return_value = {'status': 200, 'body': {'province_id': 42}}
        self.assertEqual(self.client.post('/api/projection/province', json={'province_id': 42, 'taxes': 999},
                         headers=same).status_code, 422)
        self.assertEqual(self.client.post('/api/projection/province', json={'province_id': 42}).status_code, 403)
        worker.assert_not_called()
        response = self.client.post('/api/projection/province', json={'province_id': 42}, headers=same)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'province_id': 42})
        build.assert_called_once_with(self.connection, 42)
        worker.assert_called_once_with({'server': 'snapshot'})
        self.assertEqual(PROJECTION_SLOTS.acquire(blocking=False), True)
        try:
            with patch('rpc_preview.PROJECTION_WAIT_SECONDS', 0):
                self.assertEqual(self.client.post('/api/projection/province', json={'province_id': 42},
                                 headers=same).status_code, 503)
        finally:
            PROJECTION_SLOTS.release()

    @patch('rpc_preview.run_province_worker')
    @patch('rpc_preview.build_province_snapshot')
    def test_parallel_projections_wait_for_available_slot(self, build, worker):
        entered, queued, release = Event(), Event(), Event()
        build.return_value = {'server': 'snapshot'}
        def calculate(_snapshot):
            if not entered.is_set():
                entered.set()
                if not release.wait(5):
                    raise RuntimeError('Test synchronization timed out')
            return {'status': 200, 'body': {'ok': True}}
        worker.side_effect = calculate
        self.client.cookies.set(SESSION_COOKIE, 'a' * 43)
        def send():
            return self.client.post('/api/projection/province', json={'province_id': 42},
                                    headers={'Origin': 'https://sixiemeterre.ru'})
        class ObservedSlots:
            def acquire(self, blocking, timeout):
                if entered.is_set(): queued.set()
                return PROJECTION_SLOTS.acquire(blocking, timeout)
            def release(self): PROJECTION_SLOTS.release()
        with patch('rpc_preview.PROJECTION_SLOTS', ObservedSlots()), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(send)
            try:
                self.assertTrue(entered.wait(5))
                second = pool.submit(send)
                self.assertTrue(queued.wait(5))
                release.set()
                self.assertEqual(first.result(timeout=5).status_code, 200)
                self.assertEqual(second.result(timeout=5).status_code, 200)
                self.assertEqual(worker.call_count, 2)
            finally:
                release.set()


if __name__ == '__main__':
    unittest.main()
