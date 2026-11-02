// Incomplete VPS adapter. Do not enable on the public site until migration checks pass.
const unsupported = () => ({data: null, error: {message: 'Этот раздел ещё не перенесён на VPS'}, status: 501});
const publicRoutes = new Map([['map', '/api/public/map'], ['game/calendar', '/api/public/game/calendar'],
  ['health', '/api/public/health']]);
const privateRoutes = new Map([['auth/me', '/api/me'], ['my/states', '/api/my/states'],
  ['admin/states', '/api/admin/states'], ['preferences', '/api/preferences'],
  ['notifications', '/api/notifications']]);
const wallRoutes = new Map([['list', '/api/public/wall/posts'], ['filters', '/api/public/wall/filters'],
  ['settings', '/api/public/wall/settings']]);
const wallWrites = new Set(['react', 'comment', 'create', 'delete', 'set_posting']);

export function createVpsClient(fetchImpl = globalThis.fetch) {
  async function request(route, method = 'GET', body) {
    try {
      const options = {method, credentials: 'same-origin'};
      if (body !== undefined) {
        options.headers = {'Content-Type': 'application/json'};
        options.body = JSON.stringify(body);
      }
      const response = await fetchImpl(route, options);
      if (!response.ok) return {data: null, error: {message: 'Не удалось выполнить запрос'}, status: response.status};
      return {data: await response.json(), error: null, status: response.status};
    } catch {
      return {data: null, error: {message: 'Не удалось подключиться к серверу'}, status: 0};
    }
  }

  async function rpc(name, args = {}) {
    if (name === 'fauxlore_api' && typeof args.path === 'string') {
      const match = /^(my|admin)\/states\/([1-9][0-9]*)\/(tax-rates|estate-tax-rates|trade-duty|trade-overview|indicators|politics)$/.exec(args.path);
      if (match && Number(match[2]) < 16777216) {
        const [, prefix, id, kind] = match;
        if ((args.method || 'GET') === 'GET') return request(`/api/states/${id}/details/${prefix}/${kind}`);
        if (args.method === 'POST' && kind === 'trade-duty' && args.body &&
            Object.keys(args.body).length === 1 && typeof args.body.rate === 'number' &&
            Number.isFinite(args.body.rate) && typeof args.request_id === 'string') {
          return request(`/api/states/${id}/trade-duty/${prefix}`, 'POST', {rate: args.body.rate, request_id: args.request_id});
        }
        return unsupported();
      }
    }
    if (['military_api', 'garrison_api', 'colonization_api'].includes(name) && args.action === 'snapshot' &&
        Number.isSafeInteger(args.target_state) && args.target_state > 0 && args.target_state < 16777216 &&
        (args.province_key == null) && args.payload && typeof args.payload === 'object' &&
        !Array.isArray(args.payload) && Object.keys(args.payload).length === 0) {
      return request(`/api/states/${args.target_state}/snapshot/${name.replace('_api', '')}`);
    }
    if (name === 'fauxlore_api' && (args.method || 'GET') === 'GET') {
      const route = publicRoutes.get(args.path) || privateRoutes.get(args.path);
      if (!route) return unsupported();
      const result = await request(route);
      if (args.path === 'auth/me' && result.status === 401) return {data: {user: null}, error: null, status: 200};
      return result;
    }
    if (name === 'map_revision_api') return request('/api/public/map/revision');
    if (name === 'wall_api') {
      let route = wallRoutes.get(args.action);
      if (!route) {
        if (wallWrites.has(args.action) && args.payload && typeof args.payload === 'object' && !Array.isArray(args.payload)) {
          return request(`/api/wall/${args.action}`, 'POST', args.payload);
        }
        return unsupported();
      }
      let query = '';
      if (args.action === 'list') {
        const payload = args.payload || {}, params = new URLSearchParams();
        for (const key of ['filter', 'state_key', 'limit', 'offset']) {
          if (payload[key] != null) params.set(key, String(payload[key]));
        }
        if (params.size) query = `?${params}`;
      }
      const result = await request(`/api/wall/${args.action}${query}`);
      return result.status === 401 ? request(route + query) : result;
    }
    if (name === 'state_journal_api') {
      const stateId = Number(args.target_state);
      if (!Number.isSafeInteger(stateId) || stateId < 1 || stateId >= 16777216) return unsupported();
      const base = `/api/states/${stateId}/journal`;
      if (args.action === 'snapshot') return request(base);
      if (args.action === 'save_player' && typeof args.note === 'string') return request(`${base}/player`, 'POST', {note: args.note});
      if (args.action === 'save_admin' && typeof args.note === 'string') return request(`${base}/admin`, 'POST', {note: args.note});
    }
    return unsupported();
  }

  return {
    rpc,
    auth: {
      getSession: async () => {
        const result = await request('/auth/session');
        if (result.error) return {data: {session: null}, error: result.error};
        return {data: {session: result.data.authenticated ? {user: {}} : null}, error: null};
      },
      signOut: async () => {
        const result = await request('/auth/logout', 'POST', {});
        return {error: result.error};
      },
    },
    functions: {invoke: async (name, options = {}) => {
      const body = options.body;
      if (name === 'province-projection' && body && Object.keys(body).length === 2 &&
          Number.isSafeInteger(body.state_id) && body.state_id > 0 && body.state_id < 16777216 && ['provinces', 'politics', 'trade', 'finance'].includes(body.view)) {
        return request('/api/projection/state', 'POST', {state_id: body.state_id, view: body.view});
      }
      if (name !== 'province-projection' || !body || Object.keys(body).length !== 1 ||
          !Number.isSafeInteger(body.province_id) || body.province_id < 1 || body.province_id >= 16777216) {
        return unsupported();
      }
      return request('/api/projection/province', 'POST', {province_id: body.province_id});
    }},
  };
}

export async function completeVpsLogin(popup, readUser, host = window) {
  let cleanup = () => {};
  try {
    const completed = new Promise((resolve, reject) => {
      const listener = event => {
        if (event.source !== popup || event.origin !== host.location.origin || event.data?.type !== 'fauxlore:vps-oauth') return;
        cleanup();
        if (event.data.success === true) resolve();
        else reject(new Error('Не удалось войти через Google'));
      };
      const timer = setTimeout(() => { cleanup(); reject(new Error('Время входа истекло')); }, 600000);
      const closed = setInterval(() => { if (popup.closed) { cleanup(); reject(new Error('Окно входа закрыто')); } }, 500);
      cleanup = () => { clearTimeout(timer); clearInterval(closed); host.removeEventListener('message', listener); };
      host.addEventListener('message', listener);
    });
    popup.location.href = '/auth/google/start';
    await completed;
    const result = await readUser();
    if (!result?.user) throw new Error('Не удалось подтвердить вход');
    return result;
  } finally {
    cleanup();
  }
}
