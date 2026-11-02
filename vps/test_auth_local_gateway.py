"""Smoke test for the loopback OAuth ingress; never contacts Google."""
import http.client
import json
from urllib.parse import parse_qs, urlsplit

def request(method, path, payload=None, headers=None):
    connection = http.client.HTTPConnection('localhost', 18093, timeout=30)
    data = json.dumps(payload).encode() if payload is not None else None
    headers = dict(headers or {})
    if data is not None: headers['Content-Type'] = 'application/json'
    try:
        connection.request(method, path, data, headers)
        response = connection.getresponse()
        return response.status, response.getheaders(), response.read()
    finally:
        connection.close()

status, headers, body = request('GET', '/auth/google/start')
assert status == 302
headers = dict((key.lower(), value) for key, value in headers)
redirect = urlsplit(headers['location'])
assert redirect.scheme == 'https' and redirect.netloc == 'accounts.google.com'
assert parse_qs(redirect.query)['redirect_uri'] == ['http://localhost:18093/auth/google/callback']
assert 'secure' in headers['set-cookie'].lower() and 'httponly' in headers['set-cookie'].lower()
assert 'dummy-local-only' not in headers['location'] and b'dummy-local-only' not in body
payload = {'path':'auth/me','method':'GET','body':{},'request_id':None}
assert request('POST', '/api/rpc/fauxlore_api', payload, {'Origin':'http://evil.example'})[0] == 403
status, _, body = request('POST', '/api/rpc/fauxlore_api', payload, {'Origin':'http://localhost:18093'})
assert status == 200 and json.loads(body)['user'] is None
assert request('POST', '/auth/logout', {}, {'Origin':'http://evil.example'})[0] == 403
print('Local OAuth ingress: redirect, secure cookie, guest API and origin restrictions passed')
