"""Check the prepared loopback service's Google redirect without exposing credentials."""
import http.client
from urllib.parse import parse_qs, urlsplit

connection = http.client.HTTPConnection('127.0.0.1', 18081, timeout=10)
try:
    connection.request('GET', '/auth/google/start')
    response = connection.getresponse()
    assert response.status == 302
    location = urlsplit(response.getheader('Location'))
    assert location.scheme == 'https' and location.netloc == 'accounts.google.com'
    assert parse_qs(location.query)['redirect_uri'] == ['https://sixiemeterre.ru/auth/google/callback']
    cookie = response.getheader('Set-Cookie').lower()
    assert 'secure' in cookie and 'httponly' in cookie and 'samesite=lax' in cookie
    response.read()
    print('Production OAuth service: configured domain and secure login cookie passed')
finally:
    connection.close()
