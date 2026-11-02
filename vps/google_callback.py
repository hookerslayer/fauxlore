"""Server-side Google callback core; no HTTP endpoint or sessions yet."""

import httpx

from google_identity import find_linked_user, verify_google_identity
from oauth_flow import OAuthFlowError, PendingGoogleLogins

TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'


def complete_google_callback(*, pending: PendingGoogleLogins, state: str,
                             browser_token: str, code: str, client_secret: str,
                             google_transport, connection):
    """Return the uniquely linked UUID; callers must provide trusted dependencies.

    The caller must set/read an HttpOnly, Secure browser-binding cookie and must
    not accept the client secret, transport or connection from the browser.
    """
    if (not isinstance(code, str) or not code or len(code) > 4096 or
            not isinstance(client_secret, str) or not client_secret):
        raise OAuthFlowError('Invalid OAuth callback')
    secrets = pending.consume(state, browser_token)
    try:
        response = httpx.post(TOKEN_ENDPOINT, data={
            'code': code,
            'client_id': pending.client_id,
            'client_secret': client_secret,
            'redirect_uri': pending.redirect_uri,
            'grant_type': 'authorization_code',
            'code_verifier': secrets.code_verifier,
        }, timeout=10.0, follow_redirects=False)
        if response.status_code != 200:
            raise OAuthFlowError('Google token exchange failed')
        token = response.json().get('id_token')
    except (httpx.HTTPError, ValueError, AttributeError) as exc:
        raise OAuthFlowError('Google token exchange failed') from exc
    if not isinstance(token, str) or not token:
        raise OAuthFlowError('Google token exchange failed')
    identity = verify_google_identity(token, pending.client_id, secrets.nonce, google_transport)
    return find_linked_user(connection, identity)
