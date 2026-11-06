"""Session primitives for the isolated VPS prototype; no HTTP routes yet."""

import hashlib
import re
import secrets
from uuid import UUID

_TOKEN_PATTERN = re.compile(r'^[A-Za-z0-9_-]{43}$')
DEFAULT_TTL = 12 * 60 * 60
_MAX_TTL = DEFAULT_TTL


def _token_hash(token):
    if not isinstance(token, str) or _TOKEN_PATTERN.fullmatch(token) is None:
        return None
    return hashlib.sha256(token.encode('ascii')).digest()


class SessionStore:
    """Database operations are transactional; the caller owns commit/rollback."""

    def __init__(self, connection, ttl_seconds=DEFAULT_TTL):
        if type(ttl_seconds) is not int or not 1 <= ttl_seconds <= _MAX_TTL:
            raise ValueError('Invalid session lifetime')
        self.connection = connection
        self.ttl_seconds = ttl_seconds

    def create(self, user_id: UUID) -> str:
        if not isinstance(user_id, UUID):
            raise ValueError('Expected a verified user UUID')
        token = secrets.token_urlsafe(32)
        digest = _token_hash(token)
        if digest is None:
            raise RuntimeError('Unexpected session token format')
        self.connection.execute(
            '''INSERT INTO fauxlore_vps_preview.sessions (token_hash, auth_user_id, expires_at)
               VALUES (%s, %s, now() + (%s * interval '1 second'))''',
            (digest, user_id, self.ttl_seconds),
        )
        return token

    def resolve(self, token: str):
        digest = _token_hash(token)
        if digest is None:
            return None
        row = self.connection.execute(
            'SELECT fauxlore_vps_preview.resolve_session(%s)', (digest,),
        ).fetchone()
        return None if row is None else row[0]

    def touch(self, token: str):
        """Extend a valid session by its configured idle lifetime."""
        digest = _token_hash(token)
        if digest is None:
            return False
        row = self.connection.execute(
            'SELECT fauxlore_vps_preview.renew_session(%s, %s)',
            (digest, self.ttl_seconds),
        ).fetchone()
        return row is not None and row[0] is True

    def revoke(self, token: str):
        digest = _token_hash(token)
        if digest is not None:
            self.connection.execute('DELETE FROM fauxlore_vps_preview.sessions WHERE token_hash=%s', (digest,))
