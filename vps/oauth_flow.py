"""Single-process OAuth state and PKCE prototype; not an HTTP login endpoint.

Pending logins are intentionally memory-only. This prototype is unsuitable for
multiple workers or a deployment requiring pending logins to survive restarts.
"""

import base64
import hashlib
import secrets
import threading
import time
from dataclasses import dataclass, field
from urllib.parse import urlencode, urlsplit


class OAuthFlowError(ValueError):
    pass


@dataclass(frozen=True)
class LoginStart:
    authorization_url: str = field(repr=False)
    browser_token: str = field(repr=False)


@dataclass(frozen=True)
class LoginSecrets:
    nonce: str = field(repr=False)
    code_verifier: str = field(repr=False)


def _digest(value: str) -> bytes:
    return hashlib.sha256(value.encode('ascii')).digest()


def _valid_token(value) -> bool:
    return isinstance(value, str) and 1 <= len(value) <= 256 and value.isascii()


class PendingGoogleLogins:
    def __init__(self, client_id: str, redirect_uri: str, *, ttl=600, capacity=1024, clock=time.monotonic,
                 allow_local_test=False):
        parts = urlsplit(redirect_uri)
        local_test = (allow_local_test and parts.scheme == 'http' and parts.netloc == 'localhost:18093')
        if (not client_id or (parts.scheme != 'https' and not local_test) or not parts.hostname or
                parts.username is not None or parts.password is not None or
                parts.query or parts.fragment or not parts.path.startswith('/') or
                ttl <= 0 or capacity <= 0):
            raise ValueError('Invalid OAuth configuration')
        self.client_id = client_id
        self.redirect_uri = redirect_uri
        self.ttl = ttl
        self.capacity = capacity
        self.clock = clock
        self._pending = {}
        self._lock = threading.Lock()

    def begin(self) -> LoginStart:
        state = secrets.token_urlsafe(32)
        browser_token = secrets.token_urlsafe(32)
        nonce = secrets.token_urlsafe(32)
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(_digest(verifier)).rstrip(b'=').decode('ascii')
        with self._lock:
            now = self.clock()
            self._pending = {key: value for key, value in self._pending.items() if value[0] > now}
            if len(self._pending) >= self.capacity:
                raise OAuthFlowError('Too many pending logins')
            self._pending[_digest(state)] = (now + self.ttl, _digest(browser_token), LoginSecrets(nonce, verifier))
        query = urlencode({'client_id': self.client_id, 'redirect_uri': self.redirect_uri,
                           'response_type': 'code', 'scope': 'openid email profile',
                           'state': state, 'nonce': nonce, 'code_challenge': challenge,
                           'code_challenge_method': 'S256'})
        return LoginStart('https://accounts.google.com/o/oauth2/v2/auth?' + query, browser_token)

    def consume(self, state: str, browser_token: str) -> LoginSecrets:
        if not _valid_token(state) or not _valid_token(browser_token):
            raise OAuthFlowError('Invalid login state')
        key = _digest(state)
        with self._lock:
            entry = self._pending.get(key)
            if entry is None:
                raise OAuthFlowError('Invalid login state')
            expires, expected_browser, result = entry
            if expires <= self.clock():
                del self._pending[key]
                raise OAuthFlowError('Expired login state')
            if not secrets.compare_digest(expected_browser, _digest(browser_token)):
                raise OAuthFlowError('Invalid login state')
            del self._pending[key]
            return result
