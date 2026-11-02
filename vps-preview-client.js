// Guest-only adapter for an isolated VPS preview. It cannot send game writes.
const disabled = () => ({data: null, error: {message: 'В тестовой копии доступен только гостевой просмотр'}, status: 403});
const readRoutes = new Map([['map', '/map'], ['auth/me', '/auth/me'], ['health', '/health'],
  ['game/calendar', '/game/calendar']]);
const wallRoutes = new Map([['list', '/wall/posts'], ['filters', '/wall/filters'], ['settings', '/wall/settings']]);

export function createPreviewClient(fetchImpl = globalThis.fetch) {
  async function rpc(name, args = {}) {
    let route;
    if (name === 'fauxlore_api' && (args.method || 'GET') === 'GET') {
      route = readRoutes.get(args.path);
    } else if (name === 'map_revision_api') {
      route = '/map/revision';
    } else if (name === 'wall_api') {
      route = wallRoutes.get(args.action);
      if (route && args.action === 'list') {
        const payload = args.payload || {}, params = new URLSearchParams();
        for (const key of ['filter', 'state_key', 'limit', 'offset']) {
          if (payload[key] != null) params.set(key, String(payload[key]));
        }
        if (params.size) route += `?${params}`;
      }
    }
    if (!route) return disabled();
    try {
      const response = await fetchImpl(`/preview-api${route}`, {method: 'GET', credentials: 'same-origin'});
      if (!response.ok) return {data: null, error: {message: 'Не удалось загрузить тестовые данные'}, status: response.status};
      return {data: await response.json(), error: null, status: response.status};
    } catch {
      return {data: null, error: {message: 'Не удалось подключиться к тестовой копии'}, status: 0};
    }
  }
  return {
    rpc,
    auth: {
      getSession: async () => ({data: {session: null}, error: null}),
      signOut: async () => ({error: null}),
      signInWithOAuth: async () => disabled(),
    },
    functions: {invoke: async () => disabled()},
  };
}
