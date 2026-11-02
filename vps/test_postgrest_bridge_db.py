"""Exercise session -> JWT -> PostgREST -> PostgreSQL; remove the test session."""
import http.client
import json
from uuid import uuid4
import psycopg
from auth_router import SESSION_COOKIE
from session_store import SessionStore

DSN = 'dbname=fauxlore_restore_filtered port=5433'

def call(name, body, token=None):
    headers = {'Origin': 'https://sixiemeterre.ru', 'Content-Type': 'application/json'}
    if token:
        headers['Cookie'] = f'{SESSION_COOKIE}={token}'
    connection = http.client.HTTPConnection('127.0.0.1', 18086, timeout=25)
    try:
        connection.request('POST', f'/api/rpc/{name}', json.dumps(body), headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()

def main():
    with psycopg.connect(DSN) as db:
        assert db.execute('SELECT current_database()').fetchone()[0] == 'fauxlore_restore_filtered'
        user, state, account = db.execute("""SELECT a.auth_user_id, s.state_id, a.id FROM fauxlore.accounts a
          JOIN fauxlore.account_states s ON s.account_id=a.id JOIN fauxlore.state_trade_policies t ON t.state_id=s.state_id
          WHERE a.role='player' AND s.layer='states' LIMIT 1""").fetchone()
        request_id = uuid4()
        administrator = db.execute("SELECT auth_user_id FROM fauxlore.accounts WHERE role='admin' AND auth_user_id IS NOT NULL LIMIT 1").fetchone()[0]
        foreign = db.execute("""SELECT state_id FROM fauxlore.state_profiles WHERE state_id NOT IN
          (SELECT s.state_id FROM fauxlore.account_states s JOIN fauxlore.accounts a ON a.id=s.account_id
           WHERE a.auth_user_id=%s AND s.layer='states') LIMIT 1""", (user,)).fetchone()[0]
        db.execute('SET ROLE fauxlore_auth')
        store = SessionStore(db, ttl_seconds=180)
        token = store.create(user)
        admin_token = store.create(administrator)
        db.commit()
        try:
            def api(path, session=None):
                return call('fauxlore_api', {'path': path, 'method': 'GET', 'body': {}, 'request_id': None}, session)
            status, guest = api('auth/me')
            assert status == 200 and guest.get('user') is None, (status, guest)
            status, guest_map = api('map')
            assert status == 200 and len(guest_map.get('provinces', [])) > 1000, (status, 'guest map unavailable')
            assert api('game/calendar')[0] == 200
            assert call('map_revision_api', {})[0] == 200
            for action in ('settings', 'filters', 'list'):
                status, result = call('wall_api', {'action': action, 'payload': {}})
                assert status == 200, (action, status, result)
            status, player = api('auth/me', token)
            assert status == 200 and player.get('user', {}).get('role') == 'player', (status, player)
            assert call('map_revision_api', {}, token)[0] == 200
            assert api('game/calendar', token)[0] == 200
            status, states = api('my/states', token)
            assert status == 200 and isinstance(states, list), (status, states)
            for path in ('my/trade-agreements', 'my/trade-settlements', 'my/trade-market',
                         'my/trade-interzone', 'my/diplomatic-proposals', 'profile', 'my/applications',
                         'notifications', 'preferences', f'my/states/{state}/indicators',
                         f'my/states/{state}/characters', f'my/states/{state}/succession',
                         f'my/states/{state}/loans', f'my/states/{state}/transit-tolls',
                         f'my/states/{state}/trade-overview',
                         f'my/states/{state}/estate-tax-rates', f'my/states/{state}/tax-rates'):
                status, result = api(path, token)
                assert status == 200, (path, status, result)
            assert api(f'my/states/{foreign}/politics', token)[0] == 403
            status, denied = api('admin/states', token)
            assert status == 403, (status, denied)
            for name in ('military_api', 'garrison_api', 'colonization_api', 'militia_api'):
                payload = {'action': 'snapshot', 'target_state': state, 'payload': {}}
                status, result = call(name, payload, token)
                assert status == 200 and isinstance(result, dict), (name, status, result)
                status, result = call(name, {**payload, 'target_state': foreign}, token)
                assert status == 403, (name, status, result)
                status, result = call(name, payload)
                assert status in (401, 403, 404), (name, status, result)
            for name in ('estate_investment_api', 'estate_fiscal_api', 'estate_social_api'):
                payload = {'action': 'snapshot', 'target_state': state}
                if name != 'estate_social_api': payload['payload'] = {}
                status, result = call(name, payload, token)
                assert status == 200 and isinstance(result, dict), (name, status, result)
                status, result = call(name, {**payload, 'target_state': foreign}, token)
                assert status == 403, (name, status, result)
                assert call(name, payload)[0] in (401, 403, 404)
            assert call('military_map_api', {}, token)[0] == 200
            assert call('military_map_api', {})[0] in (401, 403, 404)
            for name in ('admin_resources_api', 'admin_global_modifiers_api', 'admin_mercenaries_api',
                         'admin_colonization_modifiers_api', 'judge_assignments_api'):
                payload = {'action': 'snapshot'}
                status, result = call(name, payload, token)
                assert status == 403, (name, status, result)
                status, result = call(name, payload, admin_token)
                assert status == 200 and isinstance(result, (dict, list)), (name, status, result)
                status, result = call(name, payload)
                assert status in (401, 403, 404), (name, status, result)
            status, result = call('state_development_growth_api', {'target_state': state}, token)
            assert status == 200 and isinstance(result, list), (status, result)
            assert call('state_development_growth_api', {'target_state': foreign}, token)[0] == 403
            status, result = call('judge_state_statistics_api', {}, token)
            assert status == 200 and isinstance(result, list), (status, result)
            status, duty = api(f'my/states/{state}/trade-duty', token)
            assert status == 200, (status, duty)
            command = {'path': f'my/states/{state}/trade-duty', 'method': 'POST',
                       'body': {'rate': duty['rate']}, 'request_id': str(request_id)}
            status, result = call('fauxlore_api', command, token)
            assert status == 200 and result.get('unchanged') is True, (status, result)
            assert call('fauxlore_api', command, token) == (status, result)
            assert call('projection_source_api', {}, token)[0] == 404
            print('PostgREST bridge: guest, authenticated identity, role denial and private RPC restriction passed')
        finally:
            db.rollback()
            store.revoke(token)
            store.revoke(admin_token)
            db.execute('RESET ROLE')
            db.execute('DELETE FROM fauxlore.operations WHERE account_id=%s AND request_id=%s', (account, request_id))
            db.commit()

if __name__ == '__main__':
    main()
