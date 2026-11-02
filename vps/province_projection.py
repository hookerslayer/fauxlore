"""Prepare an authorized province snapshot and run the isolated JS calculator."""

import json
import subprocess
import threading
import time

import psycopg
from psycopg.types.json import Jsonb

PROJECTION_SLOTS = threading.BoundedSemaphore(1)
WORKER = '/opt/fauxlore-projection/vps/province_worker.mjs'
MAX_SNAPSHOT_BYTES = 12_000_000


def _read(connection, path):
    return connection.execute("SELECT public.fauxlore_api(%s, 'GET', %s, NULL)",
                              (path, Jsonb({}))).fetchone()[0]


def build_province_snapshot(connection, province_id: int):
    """Called only after the server has bound a verified session and DB role."""
    map_data = _read(connection, 'map')
    snapshot = {'province_id': province_id, 'routes': {'map': map_data}, 'local_events': []}
    province = next((p for p in map_data.get('provinces', []) if p.get('id') == province_id), None)
    if not province or province.get('kind') != 'land':
        return snapshot
    layers = province.get('layers') or {}
    owner = layers.get('states') or {}
    occupation = province.get('occupation')
    occupied = bool(occupation) and occupation != owner.get('name')
    rates = province.get('occupation_estate_tax_rates') if occupied else owner.get('estate_tax_rates')
    if rates is None:
        return snapshot

    snapshot['local_events'] = connection.execute(
        'SELECT public.local_events_api(%s, %s)',
        ('projection', Jsonb({'province_id': province_id})),
    ).fetchone()[0]
    # The original calculator treats this context as optional; a savepoint keeps
    # an unavailable optional route from aborting the main read-only transaction.
    try:
        with connection.transaction():
            identity = _read(connection, 'auth/me')
            role = (identity.get('user') or {}).get('role')
            prefix = 'admin' if role == 'admin' else 'my'
            states_path = 'admin/states' if role == 'admin' else 'my/states'
            states = _read(connection, states_path)
            snapshot['routes']['auth/me'] = {'user': {'role': role}}
            snapshot['routes'][states_path] = states
            controlled_name = occupation if occupied else owner.get('name')
            state = next((item for item in states if item.get('name') == controlled_name), None)
            if state is not None:
                state_id = state.get('id')
                if type(state_id) is not int or not 1 <= state_id < 16777216:
                    raise ValueError('Invalid state in database response')
                path = f'{prefix}/states/{state_id}/indicators'
                snapshot['routes'][path] = _read(connection, path)
    except psycopg.Error:
        pass
    return snapshot


def build_state_snapshot(connection, state_id: int, view: str):
    timings = {}
    phase_started = time.perf_counter()
    identity = _read(connection, 'auth/me')
    admin = (identity.get('user') or {}).get('role') == 'admin'
    prefix = 'admin' if admin else 'my'
    states_path = f'{prefix}/states'
    states = _read(connection, states_path)
    timings['auth_and_states_ms'] = round((time.perf_counter() - phase_started) * 1000)
    routes = {'auth/me': identity, states_path: states}
    if view not in ('trade', 'finance'):
        routes['map'] = _read(connection, 'map')
    # The worker independently checks membership before looking at private data.
    if any(item.get('id') == state_id for item in states):
        phase_started = time.perf_counter()
        for suffix in ('indicators',):
            path = f'{prefix}/states/{state_id}/{suffix}'
            routes[path] = _read(connection, path)
        timings['indicators_ms'] = round((time.perf_counter() - phase_started) * 1000)
        if view == 'politics':
            path = f'{prefix}/states/{state_id}/politics'
            routes[path] = connection.execute('SELECT fauxlore_vps_preview.politics_snapshot(%s)',
                                              (state_id,)).fetchone()[0]
        if view in ('trade', 'finance'):
            phase_started = time.perf_counter()
            for suffix in ('trade-overview', 'trade-duty', 'estate-tax-rates'):
                path = f'{prefix}/states/{state_id}/{suffix}'
                routes[path] = _read(connection, path)
            timings['trade_details_ms'] = round((time.perf_counter() - phase_started) * 1000)
            phase_started = time.perf_counter()
            connection.execute('RESET ROLE')
            source = connection.execute('SELECT public.projection_source_api()').fetchone()[0]
            connection.execute('SET LOCAL ROLE authenticated')
            timings['projection_source_ms'] = round((time.perf_counter() - phase_started) * 1000)
            finance_inputs = None
            if view == 'finance':
                phase_started = time.perf_counter()
                finance_inputs = connection.execute('SELECT fauxlore_vps_preview.finance_inputs(%s)',
                                                    (state_id,)).fetchone()[0]
                timings['finance_inputs_ms'] = round((time.perf_counter() - phase_started) * 1000)
                routes[f'{prefix}/states/{state_id}/tax-rates'] = finance_inputs['tax_rates']
                routes['my/trade-agreements'] = finance_inputs['agreements']
            snapshot = {'state_id': state_id, 'view': view, 'routes': routes,
                        'local_events': [], 'projection_source': source, 'finance_inputs': finance_inputs}
            snapshot['_timings'] = timings
            return snapshot
    snapshot = {'state_id': state_id, 'view': view, 'routes': routes, 'local_events': []}
    snapshot['_timings'] = timings
    return snapshot


def run_province_worker(snapshot):
    encoded = json.dumps(snapshot, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    if len(encoded) > MAX_SNAPSHOT_BYTES:
        raise RuntimeError('Projection snapshot exceeds the limit')
    try:
        process = subprocess.run(
            ['/usr/bin/node', WORKER], input=encoded, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=15, check=True,
            env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'},
        )
        result = json.loads(process.stdout)
        if (not isinstance(result, dict) or result.get('status') not in (200, 403, 404)
                or not isinstance(result.get('body'), dict)):
            raise ValueError('Invalid worker response')
        return result
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise RuntimeError('Province projection failed') from exc
