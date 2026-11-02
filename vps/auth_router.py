"""Prototype OAuth HTTP handlers. Not mounted in the guest preview service."""

import base64
import hashlib
from urllib.parse import urlsplit

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from google_callback import complete_google_callback
from google_identity import IdentityError
from oauth_flow import OAuthFlowError
from session_store import SessionStore

OAUTH_COOKIE = '__Host-fauxlore_oauth'
SESSION_COOKIE = '__Host-fauxlore_session'
_COMPLETION_SCRIPT = ("if (window.opener) window.opener.postMessage({type:'fauxlore:vps-oauth',"
                      "success:new URLSearchParams(location.search).get('status')==='ok'},location.origin);"
                      "window.close();")
_COMPLETION_HASH = base64.b64encode(hashlib.sha256(_COMPLETION_SCRIPT.encode()).digest()).decode()


def create_auth_router(*, pending, client_secret, google_transport, connection_factory, origin, allow_local_test=False):
    """All configuration/dependencies are trusted server-side values."""
    parsed = urlsplit(origin)
    callback = urlsplit(pending.redirect_uri)
    local_test = allow_local_test and parsed.scheme == 'http' and parsed.netloc == 'localhost:18093'
    if ((parsed.scheme != 'https' and not local_test) or not parsed.hostname or parsed.path not in ('', '/') or
            parsed.query or parsed.fragment or parsed.username is not None or
            parsed.password is not None or parsed.netloc != callback.netloc or
            not client_secret):
        raise ValueError('Invalid authentication configuration')
    expected_origin = f'{parsed.scheme}://{parsed.netloc}'
    router = APIRouter()

    @router.get('/auth/google/start')
    def google_start():
        try:
            start = pending.begin()
        except OAuthFlowError as exc:
            raise HTTPException(status_code=429, detail='Too many pending logins') from exc
        response = RedirectResponse(start.authorization_url, status_code=302)
        response.set_cookie(OAUTH_COOKIE, start.browser_token, max_age=pending.ttl,
                            secure=True, httponly=True, samesite='lax', path='/')
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Referrer-Policy'] = 'no-referrer'
        return response

    @router.get('/auth/google/callback')
    def google_callback(request: Request, state: str = Query(min_length=1, max_length=256),
                        code: str | None = Query(default=None, min_length=1, max_length=4096),
                        error: str | None = Query(default=None, min_length=1, max_length=100)):
        try:
            if (code is None) == (error is None):
                raise OAuthFlowError('Invalid OAuth callback')
            if error is not None:
                pending.consume(state, request.cookies.get(OAUTH_COOKIE, ''))
                raise OAuthFlowError('Google authorization cancelled')
            with connection_factory() as connection:
                user_id = complete_google_callback(
                    pending=pending, state=state, browser_token=request.cookies.get(OAUTH_COOKIE, ''),
                    code=code, client_secret=client_secret, google_transport=google_transport,
                    connection=connection,
                )
                store = SessionStore(connection)
                token = store.create(user_id)
        except (OAuthFlowError, IdentityError):
            response = RedirectResponse('/auth/complete?status=failed', status_code=303)
        else:
            response = RedirectResponse('/auth/complete?status=ok', status_code=303)
            response.set_cookie(SESSION_COOKIE, token, max_age=store.ttl_seconds,
                                secure=True, httponly=True, samesite='lax', path='/')
        response.delete_cookie(OAUTH_COOKIE, secure=True, httponly=True, samesite='lax', path='/')
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Referrer-Policy'] = 'no-referrer'
        return response

    @router.get('/auth/complete')
    def google_complete():
        return HTMLResponse(
            '<!doctype html><html lang="ru"><meta charset="utf-8">'
            '<title>Вход</title><p>Вернитесь к странице игры.</p><script>' + _COMPLETION_SCRIPT + '</script></html>',
            headers={'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer',
                     'Content-Security-Policy': f"default-src 'none'; script-src 'sha256-{_COMPLETION_HASH}'; base-uri 'none'; frame-ancestors 'none'"},
        )

    @router.get('/auth/session')
    def session_status(request: Request):
        with connection_factory() as connection:
            user_id = SessionStore(connection).resolve(request.cookies.get(SESSION_COOKIE))
        return JSONResponse({'authenticated': user_id is not None}, headers={'Cache-Control': 'no-store'})

    @router.post('/auth/logout')
    def logout(request: Request):
        if (request.headers.get('origin') != expected_origin or
                request.headers.get('sec-fetch-site') not in (None, 'same-origin')):
            raise HTTPException(status_code=403, detail='Origin rejected')
        with connection_factory() as connection:
            SessionStore(connection).revoke(request.cookies.get(SESSION_COOKIE))
        response = JSONResponse({'ok': True}, headers={'Cache-Control': 'no-store'})
        response.delete_cookie(SESSION_COOKIE, secure=True, httponly=True, samesite='lax', path='/')
        return response

    return router
