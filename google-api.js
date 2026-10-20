export const isGoogleBackend=window.FAUXLORE_CONFIG?.backend==='apps-script';
let bridgePromise,bridgeWindow,bridgeOrigin,channel;
const pending=new Map(),inflight=new Map();
const random=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
const sessionKey='fauxlore.google-session';
function bridge(){
  if(bridgePromise)return bridgePromise;
  const endpoint=window.FAUXLORE_CONFIG?.appsScriptUrl;
  if(!/^https:\/\/script\.google\.com\/macros\/s\/[A-Za-z0-9_-]+\/exec$/.test(endpoint||''))return Promise.reject(new Error('Google-сервис ещё не опубликован. Укажите адрес Apps Script в app-config.js.'));
  channel=random();
  bridgePromise=new Promise((resolve,reject)=>{
    const frame=document.createElement('iframe');frame.hidden=true;frame.title='Подключение к Fauxlore';
    const timer=setTimeout(()=>{frame.remove();bridgePromise=null;reject(new Error('Не удалось подключиться к Apps Script. Проверьте публикацию веб-приложения.'));},45000);
    function onMessage(event){
      if(event.data?.channel!==channel)return;
      if(event.data.type==='fauxlore:ready'){
        if(!/^https:\/\/(?:[a-z0-9-]+\.)?googleusercontent\.com$/.test(event.origin)&&event.origin!=='https://script.google.com')return;
        bridgeWindow=event.source;bridgeOrigin=event.origin;clearTimeout(timer);resolve();
      }
      if(event.source!==bridgeWindow||event.origin!==bridgeOrigin||event.data.type!=='fauxlore:response')return;
      const entry=pending.get(event.data.id);if(!entry)return;pending.delete(event.data.id);clearTimeout(entry.timer);
      const result=event.data.result;if(!result?.ok){const error=new Error(result?.error||'Ошибка Google-сервиса');error.status=result?.status;entry.reject(error);}else entry.resolve(result.data);
    }
    window.addEventListener('message',onMessage);
    frame.src=endpoint+'?bridge=1&origin='+encodeURIComponent(location.origin)+'&channel='+channel;document.body.append(frame);
  });
  return bridgePromise;
}
async function request(path,options){
  const adjacencyPromise=path==='map'?fetch('map-data/province-adjacency.json').then(async response=>{if(!response.ok)throw new Error('Не найдены связи провинций');return response.json();}):null;
  try{
  await bridge();const id=crypto.randomUUID(),method=options.method||'GET';
  const message={path,method,body:options.body?JSON.parse(options.body):{},token:sessionStorage.getItem(sessionKey),request_id:id,origin:location.origin};
  const result=await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Ответ Google задерживается. Результат команды '+id+' пока неизвестен; обновите данные перед повторным действием.'));},120000);
    pending.set(id,{resolve,reject,timer});bridgeWindow.postMessage({type:'fauxlore:request',channel,id,request:message},bridgeOrigin);
  });
  if(result?.token)sessionStorage.setItem(sessionKey,result.token);
  if(path==='auth/logout')sessionStorage.removeItem(sessionKey);
  if(adjacencyPromise){
    const adjacency=await adjacencyPromise,visible=new Set(result.provinces.map(p=>Number(p.id)));
    result.adjacency=Object.fromEntries(Object.entries(adjacency).filter(([id])=>visible.has(Number(id))).map(([id,neighbors])=>[id,neighbors.filter(neighbor=>visible.has(Number(neighbor)))]));
  }
  return result;
  }catch(error){if(adjacencyPromise)void adjacencyPromise.catch(()=>{});throw error;}
}
export function googleApi(path,options={}){
  const key=path;
  if((options.method||'GET')!=='GET')return request(path,options);
  if(inflight.has(key))return inflight.get(key);
  const promise=request(path,options).finally(()=>inflight.delete(key));inflight.set(key,promise);return promise;
}
const mapDbName='fauxlore-map-cache-v1',mapStoreName='snapshots';
function openMapCache(){return new Promise((resolve,reject)=>{if(!('indexedDB'in window))return reject(new Error('IndexedDB недоступна'));const request=indexedDB.open(mapDbName,1);request.onupgradeneeded=()=>{if(!request.result.objectStoreNames.contains(mapStoreName))request.result.createObjectStore(mapStoreName);};request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error||new Error('Не удалось открыть локальный кэш карты'));});}
async function readCachedMap(){
  const db=await openMapCache();return new Promise((resolve,reject)=>{const transaction=db.transaction(mapStoreName,'readonly'),request=transaction.objectStore(mapStoreName).get('map');request.onsuccess=()=>resolve(request.result||null);request.onerror=()=>reject(request.error||new Error('Не удалось прочитать локальный кэш карты'));transaction.oncomplete=()=>db.close();transaction.onerror=()=>{db.close();reject(transaction.error||new Error('Ошибка чтения локального кэша карты'));};});
}
async function writeCachedMap(value){
  const db=await openMapCache();return new Promise((resolve,reject)=>{const transaction=db.transaction(mapStoreName,'readwrite');transaction.objectStore(mapStoreName).put(value,'map');transaction.oncomplete=()=>{db.close();resolve();};transaction.onerror=()=>{db.close();reject(transaction.error||new Error('Не удалось обновить локальный кэш карты'));};transaction.onabort=()=>{db.close();reject(transaction.error||new Error('Обновление локального кэша карты отменено'));};});
}
function isMapPayload(value){return value&&Array.isArray(value.provinces)&&Array.isArray(value.categories)&&Array.isArray(value.region);}
export async function loadInitialMap(){
  if(!isGoogleBackend)return googleApi('map');
  let cached=null;try{cached=await readCachedMap();}catch{}
  if(!isMapPayload(cached))return googleApi('map').then(async data=>{try{await writeCachedMap(data);}catch{}return data;});
  googleApi('map').then(async fresh=>{
    try{await writeCachedMap(fresh);}catch{}
    if(JSON.stringify(fresh)!==JSON.stringify(cached))window.dispatchEvent(new CustomEvent('map:cache-update',{detail:fresh}));
  }).catch(error=>window.dispatchEvent(new CustomEvent('map:cache-error',{detail:error})));
  return cached;
}
export async function googleLogin(){
  const popup=window.open('about:blank','fauxlore-google','popup,width=520,height=680');
  if(!popup)throw new Error('Разрешите всплывающее окно для входа через Google');
  const verifier=random(),digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier)),challenge=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
  try{
    const site=new URL('.',location.href).href.replace(/\/$/,'');
    const start=await googleApi('auth/start',{method:'POST',body:JSON.stringify({origin:location.origin,site,challenge})});
    const completion=new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{window.removeEventListener('message',onMessage);reject(new Error('Время входа истекло'));},600000);
      function onMessage(event){if(event.source!==popup||event.origin!==location.origin||event.data?.type!=='fauxlore:oauth'||event.data.state!==start.state)return;clearTimeout(timer);window.removeEventListener('message',onMessage);resolve(event.data.ticket);}
      window.addEventListener('message',onMessage);
    });
    popup.location.href=start.url;const ticket=await completion;popup.close();return await googleApi('auth/complete',{method:'POST',body:JSON.stringify({ticket,verifier})});
  }catch(error){popup.close();throw error;}
}
