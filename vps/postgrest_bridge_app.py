"""Loopback-only session bridge; database and PostgREST port are server configuration."""
import os
from pathlib import Path
import psycopg
from fastapi import FastAPI
from postgrest_bridge import create_bridge

def create_app():
    secret_path = os.environ.get('FAUXLORE_POSTGREST_JWT_FILE', '/etc/fauxlore/postgrest-preview.jwt')
    database_dsn = os.environ.get(
        'FAUXLORE_BRIDGE_DSN',
        'dbname=fauxlore_restore_filtered port=5433 user=fauxlore_rpc connect_timeout=3',
    )
    upstream_port = int(os.environ.get('FAUXLORE_POSTGREST_PORT', '18085'))
    secret = Path(secret_path).read_bytes()
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.include_router(create_bridge(
        connection_factory=lambda: psycopg.connect(database_dsn), secret=secret,
        upstream_port=upstream_port))
    return app
