"""OAuth test for a local SSH tunnel; never bind this app to a public port."""
import os
from pathlib import Path
import psycopg
from fastapi import FastAPI
from google.auth.transport.requests import Request as GoogleRequest
from auth_router import create_auth_router
from oauth_flow import PendingGoogleLogins

ORIGIN = 'http://localhost:18093'
CALLBACK = ORIGIN + '/auth/google/callback'

def create_app():
    client_id = os.environ.get('FAUXLORE_GOOGLE_CLIENT_ID', '')
    directory = os.environ.get('CREDENTIALS_DIRECTORY', '')
    if not client_id or not directory:
        raise RuntimeError('Google OAuth configuration is missing')
    secret = (Path(directory) / 'google_client_secret').read_text(encoding='utf-8').strip()
    if not secret or len(secret) > 4096:
        raise RuntimeError('Google OAuth credential is invalid')
    google_request = GoogleRequest()
    def google_transport(url, method='GET', **kwargs):
        kwargs.setdefault('timeout', 10.0)
        return google_request(url, method=method, **kwargs)
    pending = PendingGoogleLogins(client_id, CALLBACK, allow_local_test=True)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.include_router(create_auth_router(pending=pending, client_secret=secret, google_transport=google_transport,
        connection_factory=lambda: psycopg.connect('dbname=fauxlore_restore_filtered port=5433 user=fauxlore_auth connect_timeout=3'),
        origin=ORIGIN, allow_local_test=True))
    return app
