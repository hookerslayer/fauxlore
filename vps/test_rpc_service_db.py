"""Test the loopback service with short-lived snapshot sessions; clean up afterwards."""

import http.client
import json
import secrets
from uuid import uuid4

import psycopg
from auth_router import SESSION_COOKIE
from session_store import SessionStore

DSN = 'dbname=fauxlore_restore_filtered port=5433'


def request(path, token=None, extra_headers=None, method='GET', payload=None):
    headers = dict(extra_headers or {})
    if token:
        headers['Cookie'] = f'{SESSION_COOKIE}={token}'
    body = None
    if payload is not None:
        body = json.dumps(payload).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    connection = http.client.HTTPConnection('127.0.0.1', 18083, timeout=40)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


def main():
    tokens = []
    fixture_created = False
    fixture_post = 1_000_000_000 + secrets.randbelow(1_000_000_000)
    duty_request = uuid4()
    marker = ('isolated-vps-test-' + secrets.token_hex(16)).ljust(1500, 'x')
    with psycopg.connect(DSN) as setup:
        assert setup.execute('SELECT current_database()').fetchone()[0] == 'fauxlore_restore_filtered'
        users = {}
        for role in ('player', 'admin'):
            row = setup.execute('''SELECT a.auth_user_id, a.id FROM fauxlore.accounts a
                JOIN auth.users u ON u.id=a.auth_user_id
                JOIN auth.identities i ON i.user_id=u.id AND i.provider='google'
                WHERE a.role=%s AND u.email_confirmed_at IS NOT NULL
                  AND i.identity_data->>'email_verified'='true'
                  AND (%s <> 'player' OR EXISTS (SELECT 1 FROM fauxlore.account_states x
                       WHERE x.account_id=a.id)) LIMIT 1''', (role, role)).fetchone()
            assert row is not None
            users[role] = row[0]
            if role == 'player':
                fixture_author = row[1]
        owned = setup.execute('''SELECT s.state_id FROM fauxlore.account_states s
            JOIN fauxlore.accounts a ON a.id=s.account_id WHERE a.auth_user_id=%s LIMIT 1''',
            (users['player'],)).fetchone()[0]
        assert setup.execute('SELECT internal_duty_rate FROM fauxlore.state_trade_policies WHERE state_id=%s', (owned,)).fetchone() is not None
        before_rate = setup.execute('SELECT internal_duty_rate FROM fauxlore.state_trade_policies WHERE state_id=%s', (owned,)).fetchone()[0]
        trial_rate = 0 if before_rate != 0 else 1
        with psycopg.connect(DSN) as writer:
            writer.execute('SET LOCAL ROLE authenticated')
            writer.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (str(users['admin']),))
            trial_id = uuid4()
            from psycopg.types.json import Jsonb
            sql = "SELECT public.fauxlore_api(%s, 'POST', %s, %s)"
            params = (f'admin/states/{owned}/trade-duty', Jsonb({'rate': trial_rate}), trial_id)
            first = writer.execute(sql, params).fetchone()[0]
            assert first['rate'] == trial_rate and writer.execute(sql, params).fetchone()[0] == first
            writer.rollback()
        assert setup.execute('SELECT internal_duty_rate FROM fauxlore.state_trade_policies WHERE state_id=%s', (owned,)).fetchone()[0] == before_rate
        foreign = setup.execute('''SELECT p.state_id FROM fauxlore.state_profiles p
            WHERE NOT EXISTS (SELECT 1 FROM fauxlore.account_states s JOIN fauxlore.accounts a ON a.id=s.account_id
              WHERE a.auth_user_id=%s AND s.state_id=p.state_id) LIMIT 1''', (users['player'],)).fetchone()[0]
        def politics_rows():
            return setup.execute('''SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY group_type, group_key), '[]'::jsonb)
                FROM fauxlore.state_group_politics p WHERE state_id=%s''', (owned,)).fetchone()[0]
        before = politics_rows()
        with psycopg.connect(DSN) as reader:
            reader.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (str(users['player']),))
            expected = reader.execute("SELECT fauxlore.succession_api(%s, 'GET', '{}'::jsonb, NULL)",
                                      (f'my/states/{owned}/politics',)).fetchone()[0]
            reader.rollback()
        with psycopg.connect(DSN) as reader:
            reader.execute('SET LOCAL ROLE authenticated')
            assert not reader.execute("SELECT has_function_privilege(current_user, 'public.projection_source_api()', 'EXECUTE')").fetchone()[0]
            reader.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (str(users['player']),))
            actual = reader.execute('SELECT fauxlore_vps_preview.politics_snapshot(%s)', (owned,)).fetchone()[0]
            assert actual == expected
            reader.commit()
        assert politics_rows() == before
        with psycopg.connect(DSN) as reader:
            reader.execute('SET LOCAL ROLE authenticated')
            reader.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (str(users['player']),))
            provinces = reader.execute("SELECT public.fauxlore_api('map', 'GET', '{}'::jsonb, NULL)").fetchone()[0]['provinces']
            def accessible(province):
                owner = (province.get('layers') or {}).get('states') or {}
                occupation = province.get('occupation')
                rates = (province.get('occupation_estate_tax_rates') if occupation and occupation != owner.get('name')
                         else owner.get('estate_tax_rates'))
                return rates is not None
            available = next(p['id'] for p in provinces if p.get('kind') == 'land' and accessible(p))
            unavailable = next(p['id'] for p in provinces if p.get('kind') == 'land' and not accessible(p))
        setup.execute('''INSERT INTO fauxlore.wall_posts (id,account_id,body)
            OVERRIDING SYSTEM VALUE VALUES (%s,%s,%s)''', (fixture_post, fixture_author, marker))
        setup.commit()
        fixture_created = True
        store = None
        try:
            setup.execute('SET ROLE fauxlore_auth')
            store = SessionStore(setup, ttl_seconds=60)
            for role in ('player', 'admin'):
                tokens.append(store.create(users[role]))
            setup.commit()
            assert request('/api/my/states')[0] == 401
            status, player = request('/api/me', tokens[0], {'X-User-Id': str(users['admin'])})
            assert status == 200 and player['user']['role'] == 'player'
            assert request('/api/my/states', tokens[0])[0] == 200
            assert request('/api/preferences', tokens[0])[0] == 200
            assert request('/api/notifications', tokens[0])[0] == 200
            status, posts = request('/api/wall/list?limit=6', tokens[0])
            assert status == 200 and isinstance(posts, list)
            assert request('/api/admin/states', tokens[0])[0] == 403
            assert request(f'/api/states/{owned}/journal', tokens[0])[0] == 200
            assert request(f'/api/states/{foreign}/journal', tokens[0])[0] == 403
            for kind in ('military', 'garrison', 'colonization'):
                assert request(f'/api/states/{owned}/snapshot/{kind}', tokens[0])[0] == 200
                assert request(f'/api/states/{foreign}/snapshot/{kind}', tokens[0])[0] == 403
                assert request(f'/api/states/{owned}/snapshot/{kind}')[0] == 401
            for kind in ('tax-rates', 'estate-tax-rates', 'trade-duty', 'trade-overview', 'indicators', 'politics'):
                status, details = request(f'/api/states/{owned}/details/my/{kind}', tokens[0])
                assert status == 200, (kind, status, details)
                assert request(f'/api/states/{foreign}/details/my/{kind}', tokens[0])[0] == 403
                assert request(f'/api/states/{owned}/details/admin/{kind}', tokens[0])[0] == 403
            duty = request(f'/api/states/{owned}/details/my/trade-duty', tokens[0])[1]
            duty_body = {'rate': duty['rate'], 'request_id': str(duty_request)}
            assert request(f'/api/states/{owned}/trade-duty/my', tokens[0], method='POST', payload=duty_body)[0] == 403
            assert request(f'/api/states/{foreign}/trade-duty/my', tokens[0], {'Origin': 'https://sixiemeterre.ru'}, method='POST', payload=duty_body)[0] == 403
            status, changed = request(f'/api/states/{owned}/trade-duty/my', tokens[0], {'Origin': 'https://sixiemeterre.ru'}, method='POST', payload=duty_body)
            assert status == 200 and changed.get('unchanged') is True, (status, changed)
            assert request(f'/api/states/{owned}/trade-duty/my', tokens[0], {'Origin': 'https://sixiemeterre.ru'}, method='POST', payload=duty_body) == (status, changed)
            same = {'Origin': 'https://sixiemeterre.ru', 'Sec-Fetch-Site': 'same-origin'}
            projection = {'province_id': available}
            assert request('/api/projection/province', None, same, method='POST', payload=projection)[0] == 401
            assert request('/api/projection/province', tokens[0], method='POST', payload=projection)[0] == 403
            assert request('/api/projection/province', tokens[0], same, method='POST',
                           payload={**projection, 'taxes': 999})[0] == 422
            status, projected = request('/api/projection/province', tokens[0], same, method='POST', payload=projection)
            assert status == 200, (status, projected)
            status, denied = request('/api/projection/province', tokens[0], same, method='POST',
                                     payload={'province_id': unavailable})
            assert status == 403, (status, denied)
            for view in ('provinces', 'politics', 'trade', 'finance'):
                status, result = request('/api/projection/state', tokens[0], same, method='POST',
                                         payload={'state_id': owned, 'view': view})
                assert status == 200 and result['state_id'] == owned, (view, status, result)
                if view in ('trade', 'finance'):
                    assert 'provinces' not in result and 'projection_source' not in result
                    assert 'finance_inputs' not in result
                    assert isinstance(result['zones'], list)
                if view == 'finance':
                    assert isinstance(result.get('finance'), dict) and result['finance']
                status, result = request('/api/projection/state', tokens[0], same, method='POST',
                                         payload={'state_id': foreign, 'view': view})
                assert status == 403, (view, status, result)
            reaction = {'post_id': fixture_post, 'reaction': 'like'}
            assert request('/api/wall/react', tokens[0], method='POST', payload=reaction)[0] == 403
            assert request('/api/wall/react', None, same, method='POST', payload=reaction)[0] == 401
            assert request('/api/wall/delete', tokens[0], same, method='POST', payload={'post_id': fixture_post})[0] == 403
            assert request('/api/wall/react', tokens[0], same, method='POST', payload=reaction)[0] == 200
            assert request('/api/wall/comment', tokens[0], same, method='POST',
                           payload={'post_id': fixture_post, 'body': 'isolated test comment'})[0] == 200
            with psycopg.connect(DSN) as observer:
                assert observer.execute('SELECT count(*) FROM fauxlore.wall_reactions WHERE post_id=%s', (fixture_post,)).fetchone()[0] == 1
                assert observer.execute('SELECT count(*) FROM fauxlore.wall_comments WHERE post_id=%s', (fixture_post,)).fetchone()[0] == 1
            status, admin = request('/api/me', tokens[1])
            assert status == 200 and admin['user']['role'] == 'admin'
            assert request('/api/admin/states', tokens[1])[0] == 200
            assert request(f'/api/states/{foreign}/journal', tokens[1])[0] == 200
            print('Loopback API: session-bound player/admin access passed')
        finally:
            setup.rollback()
            setup.execute('RESET ROLE')
            for token in tokens:
                store.revoke(token)
            setup.execute('DELETE FROM fauxlore.operations WHERE account_id=%s AND request_id=%s', (fixture_author, duty_request))
            if fixture_created:
                setup.execute('DELETE FROM fauxlore.wall_posts WHERE id=%s AND body=%s', (fixture_post, marker))
            setup.commit()


if __name__ == '__main__':
    main()
