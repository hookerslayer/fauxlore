"""Read-only authenticated RPC prototype; not mounted in the public service."""

import json
import logging
import time
from typing import Literal
from uuid import UUID

import psycopg
from fastapi import APIRouter, HTTPException, Path, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, StrictBool, StrictFloat, StrictInt, StrictStr, ValidationError, conint, constr
from psycopg.types.json import Jsonb
from starlette.concurrency import run_in_threadpool

from auth_router import SESSION_COOKIE
from province_projection import PROJECTION_SLOTS, build_province_snapshot, build_state_snapshot, run_province_worker
from session_store import SessionStore

_ORIGIN = 'https://sixiemeterre.ru'
PROJECTION_WAIT_SECONDS = 20
_LOGGER = logging.getLogger(__name__)
_LOGGER.setLevel(logging.INFO)


class StrictPayload(BaseModel):
    class Config:
        extra = 'forbid'


class JournalNote(StrictPayload):
    note: constr(strict=True, max_length=30000)


class ProvinceProjectionRequest(StrictPayload):
    province_id: conint(strict=True, gt=0, lt=16777216)


class StateProjectionRequest(StrictPayload):
    state_id: conint(strict=True, gt=0, lt=16777216)
    view: Literal['provinces', 'politics', 'trade', 'finance']


class TradeDutyWrite(StrictPayload):
    rate: StrictInt | StrictFloat
    request_id: UUID


class WallReaction(StrictPayload):
    post_id: conint(strict=True, gt=0, le=9223372036854775807)
    reaction: Literal['like', 'dislike']


class WallComment(StrictPayload):
    post_id: conint(strict=True, gt=0, le=9223372036854775807)
    body: constr(strict=True, min_length=1, max_length=3000)


class WallDelete(StrictPayload):
    post_id: conint(strict=True, gt=0, le=9223372036854775807)


class WallPosting(StrictPayload):
    enabled: StrictBool


class WallCreate(StrictPayload):
    rich_body: dict
    images: list[StrictStr] = Field(default_factory=list)
    needs_verdict: StrictBool = False


_WALL_ACTIONS = {'react': WallReaction, 'comment': WallComment, 'delete': WallDelete,
                 'set_posting': WallPosting, 'create': WallCreate}
_MAX_WALL_BODY = 6_000_000


def require_same_origin(request: Request):
    if (request.headers.get('origin') != _ORIGIN or
            request.headers.get('sec-fetch-site') not in (None, 'same-origin') or
            request.headers.get('content-type', '').split(';', 1)[0].strip().lower() != 'application/json'):
        raise HTTPException(status_code=403, detail='Origin rejected')


async def bounded_json(request: Request, limit=_MAX_WALL_BODY):
    content_length = request.headers.get('content-length')
    if content_length is not None:
        try:
            length = int(content_length)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail='Invalid request') from exc
        if length < 0:
            raise HTTPException(status_code=400, detail='Invalid request')
        if length > limit:
            raise HTTPException(status_code=413, detail='Request too large')
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > limit:
            raise HTTPException(status_code=413, detail='Request too large')
    try:
        result = json.loads(body)
    except (ValueError, UnicodeDecodeError, RecursionError) as exc:
        raise HTTPException(status_code=400, detail='Invalid JSON') from exc
    if not isinstance(result, dict):
        raise HTTPException(status_code=422, detail='Invalid request')
    return result


def create_rpc_router(*, connection_factory):
    router = APIRouter()

    def with_session(request: Request, operation, *, read_only=True, repeatable=False):
        try:
            with connection_factory() as connection:
                with connection.transaction():
                    if repeatable:
                        connection.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ' +
                                           (' READ ONLY' if read_only else ''))
                    elif read_only:
                        connection.execute('SET TRANSACTION READ ONLY')
                    user_id = SessionStore(connection).resolve(request.cookies.get(SESSION_COOKIE))
                    if user_id is None:
                        raise HTTPException(status_code=401, detail='Authentication required')
                    # The identity comes only from a server-side, unexpired session.
                    connection.execute('SET LOCAL ROLE authenticated')
                    connection.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (str(user_id),))
                    return operation(connection)
        except psycopg.errors.InsufficientPrivilege as exc:
            raise HTTPException(status_code=403, detail='Access denied') from exc
        except psycopg.errors.NoDataFound as exc:
            raise HTTPException(status_code=404, detail='Not found') from exc
        except psycopg.errors.InvalidParameterValue as exc:
            raise HTTPException(status_code=400, detail='Invalid request') from exc

    def execute_for_session(request: Request, sql: str, parameters: tuple, *, read_only=True):
        return with_session(request, lambda connection: connection.execute(sql, parameters).fetchone()[0],
                            read_only=read_only)

    def response(request: Request, path: str):
        result = execute_for_session(request, "SELECT public.fauxlore_api(%s, 'GET', %s, NULL)",
                                     (path, Jsonb({})))
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    @router.get('/api/me')
    def me(request: Request):
        return response(request, 'auth/me')

    @router.get('/api/my/states')
    def my_states(request: Request):
        return response(request, 'my/states')

    @router.get('/api/preferences')
    def preferences(request: Request):
        return response(request, 'preferences')

    @router.get('/api/notifications')
    def notifications(request: Request):
        return response(request, 'notifications')

    @router.get('/api/admin/states')
    def admin_states(request: Request):
        return response(request, 'admin/states')

    @router.get('/api/states/{state_id}/journal')
    def state_journal(request: Request, state_id: int = Path(ge=1, lt=16777216)):
        result = execute_for_session(request, "SELECT public.state_journal_api('snapshot', %s, NULL)",
                                     (state_id,))
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    @router.get('/api/states/{state_id}/snapshot/{kind}')
    def game_snapshot(request: Request, kind: Literal['military', 'garrison', 'colonization'],
                      state_id: int = Path(ge=1, lt=16777216)):
        result = execute_for_session(request, 'SELECT fauxlore_vps_preview.game_snapshot(%s, %s)',
                                     (state_id, kind))
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    @router.get('/api/states/{state_id}/details/{prefix}/{kind}')
    def state_details(request: Request, prefix: Literal['my', 'admin'],
                      kind: Literal['tax-rates', 'estate-tax-rates', 'trade-duty', 'trade-overview', 'indicators', 'politics'],
                      state_id: int = Path(ge=1, lt=16777216)):
        if kind == 'politics':
            # The underlying legacy getter initializes rows; our helper rolls those changes back.
            def politics(connection):
                identity = connection.execute("SELECT public.fauxlore_api('auth/me', 'GET', %s, NULL)",
                                              (Jsonb({}),)).fetchone()[0]
                if ((identity.get('user') or {}).get('role') == 'admin') != (prefix == 'admin'):
                    raise HTTPException(status_code=403, detail='Access denied')
                return connection.execute('SELECT fauxlore_vps_preview.politics_snapshot(%s)', (state_id,)).fetchone()[0]
            result = with_session(request, politics, read_only=False)
        else:
            path = f'{prefix}/states/{state_id}/{kind}'
            result = execute_for_session(request, "SELECT public.fauxlore_api(%s, 'GET', %s, NULL)",
                                         (path, Jsonb({})))
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    @router.post('/api/states/{state_id}/trade-duty/{prefix}')
    async def set_trade_duty(request: Request, prefix: Literal['my', 'admin'],
                             state_id: int = Path(ge=1, lt=16777216)):
        require_same_origin(request)
        try:
            raw = await bounded_json(request, limit=1024)
            payload = TradeDutyWrite.model_validate(raw) if hasattr(TradeDutyWrite, 'model_validate') else TradeDutyWrite.parse_obj(raw)
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail='Invalid request') from exc
        if not 0 <= payload.rate <= 30:
            raise HTTPException(status_code=422, detail='Invalid rate')
        result = await run_in_threadpool(execute_for_session, request,
            "SELECT public.fauxlore_api(%s, 'POST', %s, %s)",
            (f'{prefix}/states/{state_id}/trade-duty', Jsonb({'rate': payload.rate}), payload.request_id),
            read_only=False)
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    async def projection_response(request: Request, model, snapshot_builder):
        require_same_origin(request)
        try:
            raw = await bounded_json(request, limit=1024)
            payload = model.model_validate(raw) if hasattr(model, 'model_validate') else model.parse_obj(raw)
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail='Invalid request') from exc
        started_at = time.perf_counter()
        slot_wait_ms = snapshot_ms = worker_ms = 0
        status_code = 500
        view = getattr(payload, 'view', 'province')
        acquired = False
        try:
            phase_started = time.perf_counter()
            acquired = await run_in_threadpool(PROJECTION_SLOTS.acquire, True, PROJECTION_WAIT_SECONDS)
            slot_wait_ms = round((time.perf_counter() - phase_started) * 1000)
            if not acquired:
                status_code = 503
                raise HTTPException(status_code=503, detail='Projection is busy')
            phase_started = time.perf_counter()
            snapshot = await run_in_threadpool(
                with_session, request, lambda connection: snapshot_builder(connection, payload),
                repeatable=True, read_only=not (isinstance(payload, StateProjectionRequest) and payload.view == 'politics'),
            )
            snapshot_ms = round((time.perf_counter() - phase_started) * 1000)
            snapshot_timings = snapshot.pop('_timings', {})
            try:
                phase_started = time.perf_counter()
                result = await run_in_threadpool(run_province_worker, snapshot)
                worker_ms = round((time.perf_counter() - phase_started) * 1000)
            except RuntimeError as exc:
                raise HTTPException(status_code=500, detail='Projection failed') from exc
            status_code = result['status']
            timings = [f'queue;dur={slot_wait_ms}', f'snapshot;dur={snapshot_ms}']
            timings.extend(f'{name.removesuffix("_ms")};dur={duration}'
                           for name, duration in snapshot_timings.items())
            timings.append(f'worker;dur={worker_ms}')
            return JSONResponse(result['body'], status_code=result['status'], headers={
                'Cache-Control': 'no-store', 'Server-Timing': ', '.join(timings),
            })
        except HTTPException as exc:
            status_code = exc.status_code
            raise
        finally:
            if acquired:
                PROJECTION_SLOTS.release()
            _LOGGER.info(
                'projection_timing view=%s slot_wait_ms=%d snapshot_ms=%d worker_ms=%d total_ms=%d status=%d',
                view, slot_wait_ms, snapshot_ms, worker_ms,
                round((time.perf_counter() - started_at) * 1000), status_code,
            )

    @router.post('/api/projection/province')
    async def province_projection(request: Request):
        return await projection_response(request, ProvinceProjectionRequest,
                                         lambda connection, payload: build_province_snapshot(connection, payload.province_id))

    @router.post('/api/projection/state')
    async def state_projection(request: Request):
        return await projection_response(request, StateProjectionRequest,
                                         lambda connection, payload: build_state_snapshot(connection, payload.state_id, payload.view))

    @router.post('/api/states/{state_id}/journal/{kind}')
    def save_journal(request: Request, payload: JournalNote, kind: Literal['player', 'admin'],
                     state_id: int = Path(ge=1, lt=16777216)):
        require_same_origin(request)
        action = {'player': 'save_player', 'admin': 'save_admin'}[kind]
        result = execute_for_session(request, 'SELECT public.state_journal_api(%s, %s, %s)',
                                     (action, state_id, payload.note), read_only=False)
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    @router.get('/api/wall/{kind}')
    def wall_read(request: Request, kind: Literal['list', 'filters', 'settings'],
                  filter: Literal['all', 'admin', 'state'] = 'all',
                  state_key: str | None = Query(default=None, max_length=150),
                  limit: int = Query(default=6, ge=1, le=50),
                  offset: int = Query(default=0, ge=0, le=100000)):
        payload = {'filter': filter, 'limit': limit, 'offset': offset} if kind == 'list' else {}
        if kind == 'list' and state_key is not None:
            payload['state_key'] = state_key
        result = execute_for_session(request, 'SELECT public.wall_api(%s, %s)', (kind, Jsonb(payload)))
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    @router.post('/api/wall/{action}')
    async def wall_write(request: Request, action: Literal['react', 'comment', 'delete', 'set_posting', 'create']):
        require_same_origin(request)
        payload = await bounded_json(request)
        try:
            model = _WALL_ACTIONS[action]
            validated = model.model_validate(payload) if hasattr(model, 'model_validate') else model.parse_obj(payload)
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail='Invalid request') from exc
        data = validated.model_dump() if hasattr(validated, 'model_dump') else validated.dict()
        if action == 'create' and (len(data['images']) > 2 or any(len(image) > 2_800_000 for image in data['images'])):
            raise HTTPException(status_code=422, detail='Invalid request')
        result = await run_in_threadpool(execute_for_session, request, 'SELECT public.wall_api(%s, %s)',
                                         (action, Jsonb(data)), read_only=False)
        return JSONResponse(result, headers={'Cache-Control': 'no-store'})

    return router
