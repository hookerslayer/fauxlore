"""Loopback-only Google login service; database is selected by server environment."""

import os
from pathlib import Path

import psycopg
from fastapi import FastAPI
from google.auth.transport.requests import Request as GoogleRequest

from auth_router import create_auth_router
from oauth_flow import PendingGoogleLogins

ORIGIN = 'https://sixiemeterre.ru'
CALLBACK = ORIGIN + '/auth/google/callback'
DATABASE_DSN = os.environ.get(
    'FAUXLORE_AUTH_DSN',
    'dbname=fauxlore_restore_filtered port=5433 user=fauxlore_auth connect_timeout=3',
)


def create_app():
    client_id = os.environ.get('FAUXLORE_GOOGLE_CLIENT_ID', '')
    credentials_directory = os.environ.get('CREDENTIALS_DIRECTORY', '')
    if not client_id or not credentials_directory:
        raise RuntimeError('Google OAuth configuration is missing')
    secret = (Path(credentials_directory) / 'google_client_secret').read_text(encoding='utf-8').strip()
    if not secret or len(secret) > 4096:
        raise RuntimeError('Google OAuth credential is invalid')
    request = GoogleRequest()

    def google_transport(url, method='GET', **kwargs):
        kwargs.setdefault('timeout', 10.0)
        return request(url, method=method, **kwargs)

    pending = PendingGoogleLogins(client_id, CALLBACK)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.include_router(create_auth_router(
        pending=pending, client_secret=secret, google_transport=google_transport,
        connection_factory=lambda: psycopg.connect(DATABASE_DSN), origin=ORIGIN,
    ))
    return app
