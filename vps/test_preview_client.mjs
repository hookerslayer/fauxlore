import assert from 'node:assert/strict';
import {createPreviewClient} from '../vps-preview-client.js';

const calls = [];
const client = createPreviewClient(async (url, options) => {
  calls.push({url, options});
  return new Response(JSON.stringify({ok: true}), {status: 200, headers: {'content-type': 'application/json'}});
});
assert.deepEqual((await client.rpc('fauxlore_api', {path: 'map', method: 'GET'})).data, {ok: true});
assert.equal(calls.at(-1).url, '/preview-api/map');
assert.equal((await client.rpc('map_revision_api')).status, 200);
assert.equal(calls.at(-1).url, '/preview-api/map/revision');
assert.equal((await client.rpc('fauxlore_api', {path: 'game/calendar', method: 'GET'})).status, 200);
assert.equal(calls.at(-1).url, '/preview-api/game/calendar');
assert.equal((await client.rpc('wall_api', {action: 'list', payload: {filter: 'state', state_key: 's:2', limit: 6}})).status, 200);
assert.equal(calls.at(-1).url, '/preview-api/wall/posts?filter=state&state_key=s%3A2&limit=6');
const before = calls.length;
for (const [name, args] of [
  ['fauxlore_api', {path: 'map', method: 'POST'}],
  ['fauxlore_api', {path: '__proto__', method: 'GET'}],
  ['wall_api', {action: 'delete', payload: {post_id: 1}}],
  ['military_api', {action: 'hire'}],
]) {
  assert.equal((await client.rpc(name, args)).status, 403);
}
assert.equal(calls.length, before);
assert.equal((await client.auth.getSession()).data.session, null);
assert.equal((await client.auth.signInWithOAuth()).status, 403);
assert.ok(calls.every(call => call.options.method === 'GET'));
console.log('Guest preview client: read-only routing and write denial passed');
