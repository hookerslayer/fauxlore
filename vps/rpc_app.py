"""Loopback-only session-bound API against the configured VPS database."""

import os
import psycopg
from fastapi import FastAPI

from rpc_preview import create_rpc_router

DATABASE_DSN = os.environ.get(
    'FAUXLORE_RPC_DSN',
    'dbname=fauxlore_restore_filtered port=5433 user=fauxlore_rpc connect_timeout=3',
)


def create_app():
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.include_router(create_rpc_router(connection_factory=lambda: psycopg.connect(DATABASE_DSN)))
    return app
