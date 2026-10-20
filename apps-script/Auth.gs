function site_(){const site=properties_().getProperty('SITE_URL');if(!site)fail_(503,'Не настроен SITE_URL');return site.replace(/\/$/,'');}
function normalizeSite_(value){
  if(typeof value!=='string'||!/^https?:\/\/[a-z0-9.-]+(?::\d+)?(?:\/[a-z0-9._~/-]*)?$/i.test(value))fail_(400,'Некорректный адрес сайта');
  const result=value.replace(/\/+$/,'');
  if(result.split('/').slice(3).some(part=>part==='.'||part==='..'))fail_(400,'Некорректный путь сайта');
  return result;
}
function sites_(){
  const raw=properties_().getProperty('SITE_URLS');let values;
  try{values=raw?JSON.parse(raw):[site_()];}catch(error){fail_(503,'SITE_URLS должен быть JSON-массивом адресов');}
  if(!Array.isArray(values)||!values.length)fail_(503,'Не настроены разрешённые сайты');
  return [...new Set(values.map(normalizeSite_))];
}
function origin_(url){const match=/^(https?:\/\/[^/]+)/.exec(normalizeSite_(url));return match[1];}
function allowedOrigin_(value){return sites_().some(site=>origin_(site)===value);}
function loginSite_(body){
  const candidates=sites_().filter(site=>origin_(site)===body.origin);
  const site=body.site==null?(candidates.length===1?candidates[0]:null):normalizeSite_(body.site);
  if(!site||!candidates.includes(site))fail_(400,'Адрес возврата не разрешён');
  return site;
}
function user_(db,token){
  if(typeof token!=='string'||token.length>200)return null;
  const session=db.rows('sessions').find(row=>row.token_hash===hash_(token)&&Date.parse(row.expires_at)>Date.now());
  return session?db.rows('accounts').find(row=>row.id===session.account_id)||null:null;
}
function require_(db,request,admin){const user=user_(db,request.token);if(!user)fail_(401,'Войдите через Google');if(admin&&user.role!=='admin')fail_(403,'Нужна роль admin');return user;}
function publicUser_(db,row){
  if(!row)return null;
  const keys=['id','email','nickname','role','reputation','avatar_type'];
  const result=Object.fromEntries(keys.map(k=>[k,row[k]]));
  result.state_ids=db.rows('account_states').filter(r=>r.account_id===row.id).map(r=>r.state_id);
  result.avatar_url=row.avatar_data?'data:'+row.avatar_type+';base64,'+db.blob(row.avatar_data):null;
  return result;
}
function authStart_(body){
  const p=properties_(),client=p.getProperty('GOOGLE_CLIENT_ID'),secret=p.getProperty('GOOGLE_CLIENT_SECRET');
  if(!client||!secret)fail_(503,'Вход через Google ещё не настроен: нужны OAuth Client ID и Client Secret в Apps Script');
  if(!allowedOrigin_(body.origin)||!/^[0-9a-f]{64}$/.test(body.challenge||''))fail_(400,'Некорректное начало входа');
  const site=loginSite_(body);
  const state=random_();CacheService.getScriptCache().put('oauth:'+state,JSON.stringify({challenge:body.challenge,site}),600);
  const query={client_id:client,redirect_uri:ScriptApp.getService().getUrl(),response_type:'code',scope:'openid email profile',state,prompt:'select_account'};
  return {state,url:'https://accounts.google.com/o/oauth2/v2/auth?'+Object.entries(query).map(([k,v])=>encodeURIComponent(k)+'='+encodeURIComponent(v)).join('&')};
}
function oauthCallback_(event){
  const cache=CacheService.getScriptCache(),state=event.parameter.state,key='oauth:'+state,cached=cache.get(key);
  if(!cached)fail_(401,'Время входа истекло. Повторите вход с карты.');cache.remove(key);
  if(event.parameter.error||!event.parameter.code)fail_(401,'Вход через Google отменён');
  const config=JSON.parse(cached),p=properties_();
  const response=UrlFetchApp.fetch('https://oauth2.googleapis.com/token',{method:'post',payload:{code:event.parameter.code,client_id:p.getProperty('GOOGLE_CLIENT_ID'),client_secret:p.getProperty('GOOGLE_CLIENT_SECRET'),redirect_uri:ScriptApp.getService().getUrl(),grant_type:'authorization_code'},muteHttpExceptions:true});
  if(response.getResponseCode()!==200)fail_(401,'Google не подтвердил вход');
  const access=JSON.parse(response.getContentText()).access_token;
  const identityResponse=UrlFetchApp.fetch('https://openidconnect.googleapis.com/v1/userinfo',{headers:{Authorization:'Bearer '+access},muteHttpExceptions:true});
  if(identityResponse.getResponseCode()!==200)fail_(401,'Не удалось подтвердить Google-аккаунт');
  const identity=JSON.parse(identityResponse.getContentText());
  if(!identity.sub||!identity.email||identity.email_verified!==true)fail_(401,'Нужен подтверждённый Google-аккаунт');
  const ticket=random_();cache.put('ticket:'+ticket,JSON.stringify({identity,challenge:config.challenge,site:config.site}),180);
  const target=config.site+'/oauth-return.html#ticket='+encodeURIComponent(ticket)+'&state='+encodeURIComponent(state);
  const escaped=target.replace(/&/g,'&amp;').replace(/"/g,'&quot;');
  return HtmlService.createHtmlOutput('<meta name="viewport" content="width=device-width"><style>body{background:#101010;color:#eee;font:16px Arial;padding:24px}a{color:#e7c667}</style><p>Google-аккаунт подтверждён.</p><a target="_top" href="'+escaped+'">Завершить вход и вернуться к карте</a>');
}
function authComplete_(db,body,requestOrigin){
  if(!/^[0-9a-f]{64}$/.test(body.ticket||'')||!/^[0-9a-f]{64}$/.test(body.verifier||''))fail_(401,'Некорректный ответ входа');
  const cache=CacheService.getScriptCache(),key='ticket:'+body.ticket,cached=cache.get(key);
  if(!cached)fail_(401,'Время входа истекло');
  const {identity,challenge,site}=JSON.parse(cached);
  if(site&&(!sites_().includes(site)||origin_(site)!==requestOrigin))fail_(401,'Этот вход начат на другом сайте');
  if(hash_(body.verifier)!==challenge)fail_(401,'Этот вход начат в другом окне');cache.remove(key);
  const accounts=db.rows('accounts'),email=identity.email.toLowerCase();
  let account=accounts.find(r=>r.google_sub===identity.sub);
  if(!account){
    const legacy=accounts.find(r=>String(r.email).toLowerCase()===email&&!r.is_test_profile);
    if(legacy){if(legacy.google_sub||(!email.endsWith('@gmail.com')&&!identity.hd))fail_(403,'Для привязки существующего аккаунта обратитесь к администратору');account=legacy;account.google_sub=identity.sub;}
    else account=db.add('accounts',{id:db.nextId('accounts'),email,nickname:String(identity.name||email.split('@')[0]).slice(0,40),password_hash:'GOOGLE_ONLY',role:'player',created_at:now_(),reputation:0,avatar_data:null,avatar_type:null,google_sub:identity.sub});
  }
  const token=random_();db.remove('sessions',r=>Date.parse(r.expires_at)<=Date.now());
  db.add('sessions',{token_hash:hash_(token),account_id:account.id,expires_at:new Date(Date.now()+7*86400000).toISOString()});
  return {user:publicUser_(db,account),token};
}
