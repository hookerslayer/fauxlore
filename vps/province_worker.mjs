// One process per request. This code uses no database, secrets or network.
import fs from 'node:fs';
import {handleProvinceProjection} from '../supabase/functions/province-projection/index.js';

try {
  const snapshot = JSON.parse(fs.readFileSync(0, 'utf8'));
  const provinceMode = Number.isSafeInteger(snapshot.province_id) && snapshot.province_id > 0 && snapshot.province_id < 16777216;
  const stateMode = Number.isSafeInteger(snapshot.state_id) && snapshot.state_id > 0 && snapshot.state_id < 16777216 &&
    ['provinces', 'politics', 'trade', 'finance'].includes(snapshot.view);
  if (provinceMode === stateMode ||
      !snapshot.routes || typeof snapshot.routes !== 'object' || !Array.isArray(snapshot.local_events)) {
    throw new Error('Invalid input');
  }
  const origin = 'http://projection.internal';
  const fetchImpl = async (url, options) => {
    const body = JSON.parse(options.body);
    if (url === `${origin}/rest/v1/rpc/fauxlore_api` && typeof body.path === 'string' &&
        Object.hasOwn(snapshot.routes, body.path)) {
      return new Response(JSON.stringify(snapshot.routes[body.path]), {status: 200});
    }
    if (url === `${origin}/rest/v1/rpc/local_events_api` && body.action === 'projection' &&
        body.payload?.province_id === snapshot.province_id) {
      return new Response(JSON.stringify(snapshot.local_events), {status: 200});
    }
    if (url === `${origin}/rest/v1/rpc/projection_source_api` && stateMode && ['trade', 'finance'].includes(snapshot.view) &&
        snapshot.projection_source && typeof snapshot.projection_source === 'object') {
      return new Response(JSON.stringify(snapshot.projection_source), {status: 200});
    }
    if (stateMode && snapshot.view === 'finance' &&
        (body.action === 'snapshot' || (url.endsWith('/military_api') && body.action === 'upkeep_snapshot')) &&
        body.target_state === snapshot.state_id && snapshot.finance_inputs) {
      const endpoint = url.slice(`${origin}/rest/v1/rpc/`.length);
      const key = {colonization_api: 'colonization', military_api: 'military'}[endpoint];
      if (key && url === `${origin}/rest/v1/rpc/${endpoint}`) {
        return new Response(JSON.stringify(snapshot.finance_inputs[key]), {status: 200});
      }
    }
    return new Response('{}', {status: 403});
  };
  const response = await handleProvinceProjection(new Request('http://projection.internal/worker', {
    method: 'POST', headers: {authorization: 'Bearer local', apikey: 'local'},
    body: JSON.stringify(provinceMode ? {province_id: snapshot.province_id} : {state_id: snapshot.state_id, view: snapshot.view}),
  }), {getEnv: name => name === 'SUPABASE_URL' ? origin : name === 'SUPABASE_SERVICE_ROLE_KEY' ? 'local-only' : undefined, fetchImpl});
  process.stdout.write(JSON.stringify({status: response.status, body: await response.json()}));
} catch {
  process.stdout.write(JSON.stringify({status: 500, body: {error: 'Не удалось рассчитать показатели провинции'}}));
  process.exitCode = 1;
}
