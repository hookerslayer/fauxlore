const values=new URLSearchParams(location.hash.slice(1));
history.replaceState(null,'',location.pathname);
if(window.opener&&/^[0-9a-f]{64}$/.test(values.get('ticket')||'')&&/^[0-9a-f]{64}$/.test(values.get('state')||'')){
  window.opener.postMessage({type:'fauxlore:oauth',ticket:values.get('ticket'),state:values.get('state')},location.origin);
  document.getElementById('result').textContent='Вход завершён. Можно вернуться к карте.';
}else document.getElementById('result').textContent='Откройте вход из окна карты и повторите попытку.';
