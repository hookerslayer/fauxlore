"""Test real writes through PostgREST configured to roll back every request."""
import http.client
import json
from uuid import uuid4
import psycopg
from auth_router import SESSION_COOKIE
from session_store import SessionStore

DSN = 'dbname=fauxlore_restore_filtered port=5433'

def call(name, data, token=None):
    headers = {'Origin': 'https://sixiemeterre.ru', 'Content-Type': 'application/json'}
    if token: headers['Cookie'] = f'{SESSION_COOKIE}={token}'
    conn = http.client.HTTPConnection('127.0.0.1', 18090, timeout=30)
    try:
        conn.request('POST', '/api/rpc/' + name, json.dumps(data), headers)
        result = conn.getresponse()
        return result.status, json.loads(result.read())
    finally:
        conn.close()

def main():
    with psycopg.connect(DSN) as db:
        assert db.execute('SELECT current_database()').fetchone()[0] == 'fauxlore_restore_filtered'
        user, state = db.execute('''SELECT a.auth_user_id,s.state_id FROM fauxlore.accounts a
            JOIN fauxlore.account_states s ON s.account_id=a.id
            WHERE a.role='player' AND a.auth_user_id IS NOT NULL AND s.layer='states' LIMIT 1''').fetchone()
        admin = db.execute("SELECT auth_user_id FROM fauxlore.accounts WHERE role='admin' AND auth_user_id IS NOT NULL LIMIT 1").fetchone()[0]
        other = db.execute('''SELECT state_id FROM fauxlore.state_profiles WHERE state_id NOT IN
            (SELECT s.state_id FROM fauxlore.account_states s JOIN fauxlore.accounts a ON a.id=s.account_id
             WHERE a.auth_user_id=%s AND s.layer='states') LIMIT 1''', (user,)).fetchone()[0]
        old_journal = db.execute('SELECT to_jsonb(j) FROM fauxlore.state_journals j WHERE state_id=%s', (state,)).fetchone()
        old_prestige = db.execute('SELECT prestige FROM fauxlore.state_profiles WHERE state_id=%s', (state,)).fetchone()[0]
        old_policies = db.execute('''SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY estate),'[]'::jsonb)
            FROM fauxlore.estate_investment_policies p WHERE state_id=%s''', (state,)).fetchone()[0]
        db.execute('SET ROLE fauxlore_auth')
        store = SessionStore(db, ttl_seconds=120)
        player_token = store.create(user)
        admin_token = store.create(admin)
        db.commit()
        try:
            marker = 'rollback-test-' + uuid4().hex
            save = {'action': 'save_player', 'target_state': state, 'note': marker}
            status, result = call('state_journal_api', save, player_token)
            assert status == 200 and result.get('player_note') == marker, (status, result)
            assert call('state_journal_api', {**save, 'target_state': other}, player_token)[0] == 403
            assert call('state_journal_api', {**save, 'action': 'save_admin'}, player_token)[0] == 403
            assert call('state_journal_api', save)[0] in (401, 403, 404)
            adjustment = {'action': 'adjust', 'target_state': state, 'resource': 'prestige', 'delta': 1}
            assert call('admin_resources_api', adjustment, player_token)[0] == 403
            status, result = call('admin_resources_api', adjustment, admin_token)
            assert status == 200 and result['prestige'] == old_prestige + 1, (status, result)
            policies = {'Знать': False, 'Духовенство': True, 'Горожане': False, 'Крестьяне': True}
            action = {'action': 'save', 'target_state': state, 'payload': {'enabled': policies}}
            status, result = call('estate_investment_api', action, player_token)
            assert status == 200 and {item['name']: item['enabled'] for item in result['estates']} == policies, (status, result)
            assert call('estate_investment_api', {**action, 'target_state': other}, player_token)[0] == 403
            with psycopg.connect(DSN) as observer:
                assert observer.execute('SELECT to_jsonb(j) FROM fauxlore.state_journals j WHERE state_id=%s', (state,)).fetchone() == old_journal
                assert observer.execute('SELECT prestige FROM fauxlore.state_profiles WHERE state_id=%s', (state,)).fetchone()[0] == old_prestige
                assert observer.execute('''SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY estate),'[]'::jsonb)
                    FROM fauxlore.estate_investment_policies p WHERE state_id=%s''', (state,)).fetchone()[0] == old_policies
            print('Rollback API: journal, estate policies and admin resources passed, with unauthorized access denied and changes reverted')
        finally:
            db.rollback()
            store.revoke(player_token)
            store.revoke(admin_token)
            db.commit()

if __name__ == '__main__': main()
