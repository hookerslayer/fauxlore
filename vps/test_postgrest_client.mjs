import assert from 'node:assert/strict';
import {createPostgrestClient} from '../vps-postgrest-client.js';
const calls = [];
const client = createPostgrestClient(async (url, options) => {
  calls.push({url, options});
  if (url.endsWith('/wall_api')) return Response.json({code: '42501', message: 'denied'}, {status: 403});
  return Response.json({ok: true});
});
const args = {path: 'my/states', method: 'GET', body: {}, request_id: null};
assert.equal((await client.rpc('fauxlore_api', args)).status, 200);
assert.equal(calls[0].url, '/api/rpc/fauxlore_api');
assert.deepEqual(JSON.parse(calls[0].options.body), args);
assert.equal((await client.rpc('wall_api', {})).error.code, '42501');
assert.equal((await client.rpc('projection_source_api', {})).status, 501);
assert.equal(calls.length, 2);
console.log('Generic PostgREST client: forwarding, errors and allowlist passed');
