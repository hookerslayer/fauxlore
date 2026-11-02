"""Temporary loopback player preview. All RPC writes go to forced-rollback PostgREST."""
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request as UpstreamRequest, urlopen
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response, JSONResponse
from starlette.concurrency import run_in_threadpool
from rpc_preview import bounded_json

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
TOKEN_FILE = Path('/run/fauxlore-browser-preview/session')

def forward(path, data, port):
    token = TOKEN_FILE.read_text(encoding='ascii').strip()
    upstream = UpstreamRequest(f'http://127.0.0.1:{port}' + path,
        data=json.dumps(data, ensure_ascii=False, allow_nan=False).encode(), method='POST',
        headers={'Origin':'https://sixiemeterre.ru', 'Content-Type':'application/json',
                 'Cookie':'__Host-fauxlore_session=' + token})
    try:
        with urlopen(upstream, timeout=55) as result:
            return result.status, result.read(30_000_001)
    except HTTPError as error:
        return error.code, error.read(1_000_000)

@app.get('/auth/session')
def session():
    return JSONResponse({'authenticated': TOKEN_FILE.exists()}, headers={'Cache-Control':'no-store'})

@app.post('/api/rpc/{name}')
async def rpc(request: Request, name: str):
    from postgrest_bridge import ALLOWED_RPC
    if name not in ALLOWED_RPC: raise HTTPException(status_code=404)
    data = await bounded_json(request, limit=6_000_000)
    status, body = await run_in_threadpool(forward, '/api/rpc/' + name, data, 18090)
    if len(body) > 30_000_000: raise HTTPException(status_code=502)
    return Response(body, status_code=status, media_type='application/json', headers={'Cache-Control':'no-store'})

@app.post('/api/projection/{kind}')
async def projection(request: Request, kind: str):
    if kind not in ('state','province'): raise HTTPException(status_code=404)
    data = await bounded_json(request, limit=1024)
    status, body = await run_in_threadpool(forward, '/api/projection/' + kind, data, 18083)
    if len(body) > 30_000_000: raise HTTPException(status_code=502)
    return Response(body, status_code=status, media_type='application/json', headers={'Cache-Control':'no-store'})
