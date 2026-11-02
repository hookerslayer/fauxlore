"""Local-only, read-only bridge for testing the restored database.

This is not the production API: authentication and write operations are absent.
Run behind a loopback-only listener with a dedicated PostgreSQL role.
"""

import os
from typing import Literal

import psycopg
from fastapi import FastAPI, Query
from psycopg.types.json import Jsonb

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


def read_query(query: str, parameters: tuple = ()):
    dsn = os.environ.get("FAUXLORE_PREVIEW_DATABASE")
    if not dsn:
        raise RuntimeError("FAUXLORE_PREVIEW_DATABASE is required")
    with psycopg.connect(dsn) as connection:
        with connection.transaction():
            connection.execute("SET TRANSACTION READ ONLY")
            connection.execute("SET LOCAL ROLE anon")
            result = connection.execute(query, parameters).fetchone()
            return result[0]


def read_map(path: str):
    return read_query(
        "SELECT public.fauxlore_api(%s, 'GET', %s, NULL)",
        (path, Jsonb({})),
    )


def read_wall(action: str, payload: dict):
    return read_query("SELECT public.wall_api(%s, %s)", (action, Jsonb(payload)))


@app.get("/health")
def health():
    result = read_map("health")
    return {"ok": result.get("ok") is True, "database": "postgresql", "mode": "preview"}


@app.get("/map")
def map_data():
    return read_map("map")


@app.get("/auth/me")
def anonymous_identity():
    return read_map("auth/me")


@app.get("/game/calendar")
def game_calendar():
    return read_map("game/calendar")


@app.get("/map/revision")
def map_revision():
    return read_query("SELECT public.map_revision_api()")


@app.get("/wall/settings")
def wall_settings():
    return read_wall("settings", {})


@app.get("/wall/filters")
def wall_filters():
    return read_wall("filters", {})


@app.get("/wall/posts")
def wall_posts(
    filter: Literal["all", "admin", "state"] = "all",
    state_key: str | None = Query(default=None, max_length=150),
    limit: int = Query(default=6, ge=1, le=50),
    offset: int = Query(default=0, ge=0, le=100000),
):
    payload = {"filter": filter, "limit": limit, "offset": offset}
    if state_key is not None:
        payload["state_key"] = state_key
    return read_wall("list", payload)
