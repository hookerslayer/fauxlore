const query = new URLSearchParams(location.search);
const hash = new URLSearchParams(location.hash.slice(1));
const nonce = query.get('login');
const error = query.get('error_description') || hash.get('error_description');
const code = query.get('code');
history.replaceState(null, '', location.pathname);
if (window.opener && /^[0-9a-f-]{36}$/.test(nonce || '') && (code || error)) {
  window.opener.postMessage({ type: 'fauxlore:supabase-oauth', nonce, code, error }, location.origin);
  document.getElementById('result').textContent = 'Google-аккаунт подтверждён. Можно вернуться к карте.';
} else document.getElementById('result').textContent = 'Откройте вход из окна карты и повторите попытку.';
