"""Google identity verification for the future server; not wired to the preview."""

from dataclasses import dataclass
from secrets import compare_digest

from google.auth.exceptions import GoogleAuthError
from google.oauth2 import id_token


class IdentityError(ValueError):
    """An identity is invalid, unverified, or cannot be linked safely."""


@dataclass(frozen=True)
class GoogleIdentity:
    subject: str
    email: str | None = None
    name: str | None = None


def verify_google_identity(token: str, client_id: str, expected_nonce: str, request):
    """Verify a Google ID token. `request` must be a trusted Google transport."""
    if not all(isinstance(v, str) and v for v in (token, client_id, expected_nonce)):
        raise IdentityError('Missing token verification configuration')
    if len(token) > 16384:
        raise IdentityError('Invalid ID token')
    try:
        claims = id_token.verify_oauth2_token(token, request, audience=client_id)
    except (ValueError, GoogleAuthError) as exc:
        raise IdentityError('Invalid ID token') from exc
    nonce = claims.get('nonce')
    subject = claims.get('sub')
    if (not isinstance(nonce, str) or not nonce or not nonce.isascii() or
            not expected_nonce.isascii() or
            not compare_digest(nonce, expected_nonce) or
            claims.get('email_verified') is not True or
            not isinstance(subject, str) or not subject or len(subject) > 255 or
            not subject.isascii() or not subject.isprintable() or
            (claims.get('azp') is not None and claims['azp'] != client_id)):
        raise IdentityError('Google identity verification failed')
    email = claims.get('email')
    name = claims.get('name')
    return GoogleIdentity(subject=subject, email=email if isinstance(email, str) else None,
                          name=name if isinstance(name, str) else None)


def find_linked_user(connection, identity: GoogleIdentity):
    """Find an existing linked Supabase UUID; never auto-link by email."""
    row = connection.execute(
        'SELECT fauxlore_vps_preview.lookup_google_user(%s)', (identity.subject,),
    ).fetchone()
    if row is not None and row[0] is not None:
        return row[0]
    if not identity.email:
        raise IdentityError('Google identity is not uniquely linked to an existing account')
    row = connection.execute('SELECT fauxlore_vps_preview.create_google_user(%s, %s, %s)',
                             (identity.subject, identity.email, identity.name)).fetchone()
    if row is None or row[0] is None:
        raise IdentityError('Google identity cannot be registered safely')
    return row[0]
