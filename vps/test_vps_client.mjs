import assert from 'node:assert/strict';
import {completeVpsLogin, createVpsClient} from '../vps-client.js';

const calls = [];
const client = createVpsClient(async (url, options) => {
  calls.push({url, options});
  if (url === '/api/me') return new Response('{}', {status: 401});
  if (url === '/auth/session') return Response.json({authenticated: true});
  if (url.startsWith('/api/wall/') && options.method === 'GET') return new Response('{}', {status: 401});
  return Response.json({ok: true});
});
assert.equal((await client.rpc('fauxlore_api', {path: 'auth/me'})).data.user, null);
assert.ok((await client.auth.getSession()).data.session.user);
assert.equal((await client.rpc('fauxlore_api', {path: 'my/states'})).status, 200);
assert.equal(calls.at(-1).url, '/api/my/states');
assert.equal((await client.rpc('fauxlore_api', {path: 'my/states/2/trade-duty'})).status, 200);
assert.equal(calls.at(-1).url, '/api/states/2/details/my/trade-duty');
const dutyId = '00000000-0000-4000-8000-000000000001';
assert.equal((await client.rpc('fauxlore_api', {path: 'my/states/2/trade-duty', method: 'POST', body: {rate: 15}, request_id: dutyId})).status, 200);
assert.deepEqual(JSON.parse(calls.at(-1).options.body), {rate: 15, request_id: dutyId});
assert.equal((await client.rpc('fauxlore_api', {path: 'my/states/2/trade-duty', method: 'POST', body: {rate: 15, role: 'admin'}, request_id: dutyId})).status, 501);
assert.equal((await client.rpc('state_journal_api', {action: 'save_player', target_state: 2, note: 'test'})).status, 200);
assert.equal(calls.at(-1).url, '/api/states/2/journal/player');
assert.equal(calls.at(-1).options.method, 'POST');
assert.deepEqual(JSON.parse(calls.at(-1).options.body), {note: 'test'});
assert.equal((await client.rpc('military_api', {action: 'snapshot', target_state: 2, payload: {}})).status, 200);
assert.equal(calls.at(-1).url, '/api/states/2/snapshot/military');
assert.equal((await client.rpc('military_api', {action: 'attack', target_state: 2, payload: {}})).status, 501);
assert.equal((await client.rpc('wall_api', {action: 'list', payload: {limit: 6}})).status, 200);
assert.equal(calls.at(-1).url, '/api/public/wall/posts?limit=6');
assert.equal((await client.rpc('wall_api', {action: 'react', payload: {post_id: 1, reaction: 'like'}})).status, 200);
assert.equal(calls.at(-1).url, '/api/wall/react');
assert.equal(calls.at(-1).options.method, 'POST');
assert.equal((await client.functions.invoke('province-projection', {body: {province_id: 42}})).status, 200);
assert.equal(calls.at(-1).url, '/api/projection/province');
assert.deepEqual(JSON.parse(calls.at(-1).options.body), {province_id: 42});
assert.equal((await client.functions.invoke('province-projection', {body: {province_id: 42, taxes: 999}})).status, 501);
assert.equal((await client.functions.invoke('province-projection', {body: {state_id: 42, view: 'provinces'}})).status, 200);
assert.equal(calls.at(-1).url, '/api/projection/state');
assert.equal((await client.functions.invoke('province-projection', {body: {state_id: 42, view: 'politics'}})).status, 200);
assert.equal(calls.at(-1).url, '/api/projection/state');
assert.equal((await client.functions.invoke('province-projection', {body: {state_id: 42, view: 'trade'}})).status, 200);
assert.equal(calls.at(-1).url, '/api/projection/state');
assert.equal((await client.functions.invoke('province-projection', {body: {state_id: 42, view: 'finance'}})).status, 200);
const count = calls.length;
for (const [name, args] of [
  ['fauxlore_api', {path: 'admin/states', method: 'PATCH'}],
  ['state_journal_api', {action: 'save_admin', target_state: '../2', note: 'test'}],
  ['wall_api', {action: 'delete'}],
]) assert.equal((await client.rpc(name, args)).status, 501);
assert.equal(calls.length, count);

let listener;
const host = {location: {origin: 'https://sixiemeterre.ru'},
  addEventListener: (_, fn) => { listener = fn; }, removeEventListener: () => { listener = undefined; }};
const popup = {location: {href: ''}, closed: false};
let reads = 0;
const login = completeVpsLogin(popup, async () => { reads++; return {user: {role: 'player'}}; }, host);
assert.equal(popup.location.href, '/auth/google/start');
listener({source: {}, origin: host.location.origin, data: {type: 'fauxlore:vps-oauth', success: true}});
listener({source: popup, origin: 'https://evil.example', data: {type: 'fauxlore:vps-oauth', success: true}});
assert.equal(reads, 0);
listener({source: popup, origin: host.location.origin, data: {type: 'fauxlore:vps-oauth', success: true}});
assert.equal((await login).user.role, 'player');
assert.equal(reads, 1);
assert.equal(listener, undefined);

const failed = completeVpsLogin(popup, async () => { throw new Error('must not read'); }, host);
listener({source: popup, origin: host.location.origin, data: {type: 'fauxlore:vps-oauth', success: false}});
await assert.rejects(failed, /Не удалось войти/);
assert.equal(listener, undefined);
console.log('VPS client: routing, write limits and popup verification passed');
