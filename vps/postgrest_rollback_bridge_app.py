"""Isolated bridge to the PostgREST instance that always rolls back writes."""
from pathlib import Path
import psycopg
from fastapi import FastAPI
from postgrest_bridge import create_bridge

def create_app():
    secret = Path('/etc/fauxlore/postgrest-preview.jwt').read_bytes()
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.include_router(create_bridge(
        connection_factory=lambda: psycopg.connect('dbname=fauxlore_restore_filtered port=5433 user=fauxlore_rpc connect_timeout=3'),
        secret=secret, rollback_test=True))
    return app
