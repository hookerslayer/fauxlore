export const isSupabaseBackend = window.FAUXLORE_CONFIG?.backend === 'supabase';
let clientPromise;
const inflight = new Map();

async function client() {
  if (!clientPromise) clientPromise = (async () => {
    const config = window.FAUXLORE_CONFIG;
    if (!/^https:\/\/[a-z0-9]+\.supabase\.co$/.test(config?.supabaseUrl || '') || !config?.supabasePublishableKey?.startsWith('sb_publishable_')) {
      throw new Error('Не настроено подключение к Supabase');
    }
    if (!window.supabase) await new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = new URL('./assets/vendor/supabase-2.118.0.js', import.meta.url).href;
      script.onload = resolve;
      script.onerror = () => reject(new Error('Не удалось загрузить клиент авторизации'));
      document.head.append(script);
    });
    return window.supabase.createClient(config.supabaseUrl, config.supabasePublishableKey, {
      auth: { flowType: 'pkce', detectSessionInUrl: false, persistSession: true, autoRefreshToken: true },
    });
  })().catch(error => { clientPromise = null; throw error; });
  return clientPromise;
}

async function request(path, options) {
  const db = await client();
  if (path === 'map/revision') {
    const { data, error } = await db.rpc('map_revision_api');
    if (error) {
      const failure = new Error(error.message || 'Не удалось проверить версию карты');
      failure.code = error.code;
      throw failure;
    }
    return data;
  }
  if (path === 'auth/logout') {
    const { error } = await db.auth.signOut({ scope: 'local' });
    if (error) throw error;
    return { ok: true };
  }
  const adjacency = path === 'map' ? fetch('map-data/province-adjacency.json').then(response => {
    if (!response.ok) throw new Error('Не найдены связи провинций');
    return response.json();
  }) : null;
  // Attach a handler immediately, even if the RPC fails before this fetch.
  if (adjacency) void adjacency.catch(() => {});
  const { data, error } = await db.rpc('fauxlore_api', {
    path, method: options.method || 'GET', body: options.body ? JSON.parse(options.body) : {},
    request_id: options.requestId || ((options.method || 'GET') === 'GET' ? null : crypto.randomUUID()),
  });
  if (error) {
    const failure = new Error(error.message || 'Не удалось выполнить запрос к карте');
    failure.code = error.code;
    throw failure;
  }
  if (adjacency) {
    const links = await adjacency, ids = new Set(data.provinces.map(p => Number(p.id)));
    data.adjacency = Object.fromEntries(Object.entries(links).filter(([id]) => ids.has(Number(id)))
      .map(([id, neighbors]) => [id, neighbors.filter(n => ids.has(Number(n)))]));
  }
  return data;
}

export function supabaseApi(path, options = {}) {
  if ((options.method || 'GET') !== 'GET') return request(path, options);
  if (!inflight.has(path)) inflight.set(path, request(path, options).finally(() => inflight.delete(path)));
  return inflight.get(path);
}

export async function militaryApi(action, stateId, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('military_api', {action, target_state: stateId || null, payload});
  if (error) {
    const failure = new Error(error.message || 'Не удалось выполнить военное действие');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function militaryMapApi() {
  const db = await client();
  const {data, error} = await db.rpc('military_map_api');
  if (error) {
    const failure = new Error(error.message || 'Не удалось загрузить военные формирования карты');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function provinceProjectionApi(provinceId) {
  const db = await client();
  const {data, error} = await db.functions.invoke('province-projection', {
    body: {province_id: Number(provinceId)},
  });
  if (error) throw new Error('Не удалось загрузить расчётные показатели провинции');
  return data;
}

export async function stateProvinceProjectionApi(stateId, view = 'provinces') {
  const db = await client();
  const {data, error} = await db.functions.invoke('province-projection', {
    body: {state_id: Number(stateId), view},
  });
  if (error) throw new Error('Не удалось загрузить расчётные показатели государства');
  return data;
}

export async function militaryMovementApi(action, formationId, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('military_movement_api', {
    action,
    formation_key: formationId,
    payload,
  });
  if (error) {
    const failure = new Error(error.message || 'Не удалось задать движение армии');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function militaryTransportApi(action, armyId, fleetId, targetProvinceId = null) {
  const db = await client();
  const {data, error} = await db.rpc('military_transport_api', {
    action,
    army_key: armyId,
    fleet_key: fleetId,
    target_province: targetProvinceId,
  });
  if (error) {
    const failure = new Error(error.message || 'Не удалось выполнить погрузку или высадку');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function militaryBattleApi(battleId, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('military_battle_api', {battle_key: battleId, payload});
  if (error) {
    const failure = new Error(error.message || 'Не удалось сохранить решение по сражению');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function navalBattlePreviewApi(battleId, settings) {
  const db = await client();
  const {data,error} = await db.functions.invoke('naval-battle-preview', {
    body:{battle_id:battleId,settings},
  });
  if(error)throw new Error(data?.error||error.message||'Не удалось рассчитать морской бой');
  if(data?.error)throw new Error(data.error);
  return data;
}

export async function militarySiegeApi(stateId = null) {
  const db = await client();
  const {data, error} = await db.rpc('military_siege_api', {target_state: stateId || null});
  if (error) {
    const failure = new Error(error.message || 'Не удалось загрузить сведения об осадах');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function militarySiegeStormApi(provinceId, route) {
  const db = await client();
  const {data, error} = await db.rpc('military_siege_storm_api', {province_key: provinceId, attack_route: route});
  if (error) {
    const failure = new Error(error.message || 'Не удалось начать штурм укрепления');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function militiaApi(action, stateId, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('militia_api', {action, target_state: stateId || null, payload});
  if (error) throw new Error(error.message || 'Не удалось выполнить действие ополчения');
  return data;
}

export async function garrisonApi(action, stateId = null, provinceId = null, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('garrison_api', {
    action, target_state: stateId, province_key: provinceId, payload,
  });
  if (error) throw new Error(error.message || 'Не удалось выполнить действие гарнизона');
  return data;
}

export async function estateInvestmentApi(action, stateId, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('estate_investment_api', {action, target_state: stateId, payload});
  if (error) throw new Error(error.message || 'Не удалось получить вложения сословий');
  return data;
}

export async function estateSocialApi(action, stateId, estate = null) {
  const db = await client();
  const {data, error} = await db.rpc('estate_social_api', {action, target_state: stateId, target_estate: estate});
  if (error) throw new Error(error.message || 'Не удалось выполнить действие сословия');
  return data;
}

export async function estateFiscalApi(action, stateId, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('estate_fiscal_api', {action, target_state: stateId, payload});
  if (error) throw new Error(error.message || 'Не удалось выполнить операцию с казной сословий');
  return data;
}

export async function colonizationApi(action, stateId, payload = {}) {
  const db = await client();
  const {data, error} = await db.rpc('colonization_api', {action, target_state: stateId || null, payload});
  if (error) {
    const failure = new Error(error.message || 'Не удалось выполнить колонизационную миссию');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function adminResourcesApi(action, targetState = null, resource = null, delta = 0) {
  const db = await client();
  const {data, error} = await db.rpc('admin_resources_api', {
    action, target_state: targetState, resource, delta,
  });
  if (error) {
    const failure = new Error(error.message || 'Не удалось изменить ресурсы государства');
    failure.code = error.code;
    throw failure;
  }
  return data;
}

export async function adminModifiersApi(action, payload = {}) {
  const db = await client();
  const {data,error}=await db.rpc('admin_modifiers_api',{action,payload});
  if(error){const failure=new Error(error.message||'Не удалось выполнить операцию с модификаторами');failure.code=error.code;throw failure;}
  return data;
}

export async function wallApi(action,payload={}){
  const db=await client();
  const {data,error}=await db.rpc('wall_api',{action,payload});
  if(error)throw new Error(error.message||'Операция со Стеной не выполнена');
  return data;
}

export async function wallVerdictManyApi(payload){
  const db=await client();
  const {data,error}=await db.rpc('wall_verdict_many',{payload});
  if(error)throw new Error(error.message||'Не удалось сохранить вердикт');
  return data;
}

export async function hasAuthenticatedSession() {
  const db = await client();
  const { data, error } = await db.auth.getSession();
  if (error) throw error;
  return Boolean(data.session?.user);
}

function mapCache(mode, value) {
  return new Promise((resolve, reject) => {
    const opening = indexedDB.open('fauxlore-supabase-cache', 1);
    opening.onupgradeneeded = () => opening.result.createObjectStore('map');
    opening.onerror = () => reject(opening.error);
    opening.onsuccess = () => {
      const db = opening.result, tx = db.transaction('map', mode), store = tx.objectStore('map');
      const key = window.FAUXLORE_CONFIG.supabaseUrl;
      const req = mode === 'readonly' ? store.get(key) : store.put(value, key);
      let result;
      req.onsuccess = () => { result = req.result; };
      tx.oncomplete = () => { db.close(); resolve(result); };
      tx.onerror = tx.onabort = () => { db.close(); reject(tx.error); };
    };
  });
}

export async function loadSupabaseInitialMap() {
  let cached;
  try { cached = await mapCache('readonly'); } catch {}
  const fresh = supabaseApi('map').then(async value => {
    try { await mapCache('readwrite', value); } catch {}
    return value;
  });
  if (!cached || !Array.isArray(cached.provinces) || !Array.isArray(cached.region)) return fresh;
  fresh.then(value => {
    if (JSON.stringify(value) !== JSON.stringify(cached)) window.dispatchEvent(new CustomEvent('map:cache-update', { detail: value }));
  }).catch(error => window.dispatchEvent(new CustomEvent('map:cache-error', { detail: error })));
  return cached;
}

export async function supabaseLogin() {
  const popup = window.open('about:blank', 'fauxlore-supabase-login', 'popup,width=520,height=680');
  if (!popup) throw new Error('Разрешите всплывающее окно для входа через Google');
  let cleanup = () => {};
  try {
    const db = await client(), nonce = crypto.randomUUID();
    const callback = new URL('supabase-return.html', location.href);
    callback.searchParams.set('login', nonce);
    const { data, error } = await db.auth.signInWithOAuth({ provider: 'google', options: {
      redirectTo: callback.href, skipBrowserRedirect: true, queryParams: { prompt: 'select_account' },
    } });
    if (error) throw error;
    const completion = new Promise((resolve, reject) => {
      const listener = event => {
        if (event.source !== popup || event.origin !== location.origin || event.data?.type !== 'fauxlore:supabase-oauth' || event.data.nonce !== nonce) return;
        cleanup();
        if (event.data.error) reject(new Error(event.data.error));
        else if (typeof event.data.code === 'string' && event.data.code.length < 4096) resolve(event.data.code);
        else reject(new Error('Некорректный ответ авторизации'));
      };
      const timer = setTimeout(() => { cleanup(); reject(new Error('Время входа истекло')); }, 600000);
      const closed = setInterval(() => { if (popup.closed) { cleanup(); reject(new Error('Окно входа закрыто')); } }, 500);
      cleanup = () => { clearTimeout(timer); clearInterval(closed); window.removeEventListener('message', listener); };
      window.addEventListener('message', listener);
    });
    popup.location.href = data.url;
    const code = await completion;
    const exchanged = await db.auth.exchangeCodeForSession(code);
    if (exchanged.error) throw exchanged.error;
    return await supabaseApi('auth/me');
  } finally { cleanup(); popup.close(); }
}
