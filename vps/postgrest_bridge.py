"""Loopback-only prototype: translate server sessions to short-lived PostgREST JWTs."""
import base64
import hashlib
import hmac
import json
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request as UpstreamRequest, urlopen

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool

from auth_router import SESSION_COOKIE
from rpc_preview import bounded_json, require_same_origin
from session_store import SessionStore
from session_store import DEFAULT_TTL

# This initial list is deliberately small while original database grants are audited.
ALLOWED_RPC = frozenset({'fauxlore_api', 'map_revision_api', 'wall_api', 'state_journal_api', 'local_events_api', 'player_contacts_api',
                         'government_form_preview_api', 'military_api', 'colonization_api', 'conquest_api', 'turn_limits_api', 'turn_report_api', 'militia_api',
                         'garrison_api', 'estate_investment_api', 'estate_social_api', 'estate_fiscal_api',
                         'military_map_api', 'military_order_api', 'military_split_api', 'military_transport_api',
                         'state_development_growth_api', 'admin_resources_api', 'admin_global_modifiers_api',
                         'admin_mercenaries_api', 'admin_colonization_modifiers_api', 'judge_assignments_api',
                         'judge_state_statistics_api', 'instant_modifier_api', 'admin_modifiers_api', 'wall_verdict_many',
                         'neutral_forces_api', 'admin_rollback_api'})


def _b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b'=').decode('ascii')


def _jwt(secret, user_id):
    claims = {'role': 'authenticated', 'sub': str(user_id), 'exp': int(time.time()) + 30}
    head = _b64(b'{"alg":"HS256","typ":"JWT"}')
    body = _b64(json.dumps(claims, separators=(',', ':')).encode('utf-8'))
    signed = f'{head}.{body}'
    return signed + '.' + _b64(hmac.new(secret, signed.encode('ascii'), hashlib.sha256).digest())


def create_bridge(*, connection_factory, secret, transport=None, rollback_test=False, upstream_port=None):
    if not isinstance(secret, bytes) or len(secret.strip()) < 32:
        raise ValueError('Invalid PostgREST signing secret')
    secret = secret.strip()
    if upstream_port is None:
        upstream_port = 18089 if rollback_test else 18085
    if type(upstream_port) is not int or not 1 <= upstream_port <= 65535:
        raise ValueError('Invalid PostgREST upstream port')
    router = APIRouter()

    def forward(name, data, token):
        headers = {'Content-Type': 'application/json', 'Accept': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        upstream = UpstreamRequest(f'http://127.0.0.1:{upstream_port}/rpc/{name}',
                                  data=json.dumps(data, ensure_ascii=False, allow_nan=False).encode('utf-8'),
                                  headers=headers, method='POST')
        try:
            with urlopen(upstream, timeout=45) as response:
                return response.status, response.read(30_000_001)
        except HTTPError as error:
            return error.code, error.read(1_000_000)
        except (URLError, TimeoutError) as exc:
            raise HTTPException(status_code=502, detail='Database API unavailable') from exc

    send = transport or forward

    def resolve(token):
        with connection_factory() as connection:
            store = SessionStore(connection)
            user_id = store.resolve(token)
            if user_id is not None:
                store.touch(token)
            return user_id

    @router.post('/api/rpc/{name}')
    async def call(request: Request, name: str):
        require_same_origin(request)
        if name not in ALLOWED_RPC:
            raise HTTPException(status_code=404, detail='Unknown RPC')
        data = await bounded_json(request, limit=6_000_000)
        try:
            json.dumps(data, allow_nan=False)
        except (ValueError, TypeError, RecursionError) as exc:
            raise HTTPException(status_code=422, detail='Invalid request') from exc
        user_id = await run_in_threadpool(resolve, request.cookies.get(SESSION_COOKIE))
        token = _jwt(secret, user_id) if user_id else None
        status, body = await run_in_threadpool(send, name, data, token)
        if len(body) > 30_000_000:
            raise HTTPException(status_code=502, detail='Database response too large')
        headers = {'Cache-Control': 'no-store'}
        if user_id:
            from starlette.responses import Response as StarletteResponse
            response = StarletteResponse(body, status_code=status, media_type='application/json', headers=headers)
            response.set_cookie(SESSION_COOKIE, request.cookies.get(SESSION_COOKIE), max_age=DEFAULT_TTL,
                                secure=True, httponly=True, samesite='lax', path='/')
            return response
        return Response(body, status_code=status, media_type='application/json', headers=headers)

    return router
