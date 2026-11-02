"""Guest-only loopback browser preview; never forwards cookies or writes."""
import json
from urllib.request import Request as UpstreamRequest, urlopen
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool

from rpc_preview import bounded_json

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

@app.post('/api/rpc/{name}')
async def guest_rpc(request: Request, name: str):
    data = await bounded_json(request, limit=4096)
    if name == 'fauxlore_api':
        allowed = (set(data) <= {'path', 'method', 'body', 'request_id'} and
                   data.get('path') in ('map', 'auth/me', 'health', 'game/calendar') and
                   data.get('method', 'GET') == 'GET' and data.get('body', {}) == {} and
                   data.get('request_id') is None)
    elif name == 'map_revision_api':
        allowed = data == {}
    elif name == 'wall_api':
        allowed = (set(data) <= {'action', 'payload'} and data.get('action') in ('settings', 'filters', 'list') and
                   isinstance(data.get('payload', {}), dict))
    else:
        allowed = False
    if not allowed:
        raise HTTPException(status_code=403, detail='Guest preview is read-only')
    def forward():
        upstream = UpstreamRequest('http://127.0.0.1:18086/api/rpc/' + name,
            data=json.dumps(data, ensure_ascii=False).encode(), method='POST',
            headers={'Origin': 'https://sixiemeterre.ru', 'Content-Type': 'application/json'})
        with urlopen(upstream, timeout=30) as response:
            return response.status, response.read(30_000_001)
    status, body = await run_in_threadpool(forward)
    if len(body) > 30_000_000:
        raise HTTPException(status_code=502, detail='Response too large')
    return Response(body, status_code=status, media_type='application/json', headers={'Cache-Control':'no-store'})
