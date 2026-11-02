import assert from 'node:assert/strict';
import {handleProvinceProjection} from '../supabase/functions/province-projection/index.js';

const request = body => new Request('https://local.example/projection', {
  method: 'POST',
  headers: {authorization: 'Bearer test-token', apikey: 'test-key', 'content-type': 'application/json'},
  body: JSON.stringify(body),
});

let calls = [];
const dependencies = {
  getEnv: key => key === 'SUPABASE_URL' ? 'https://backend.example' : 'private-server-key',
  fetchImpl: async (url, options) => {
    calls.push({url, options});
    const body = JSON.parse(options.body);
    if (body.path === 'auth/me') return Response.json({user: {role: 'player'}});
    if (body.path === 'my/states') return Response.json([]);
    throw new Error('Unexpected backend request');
  },
};

const invalid = await handleProvinceProjection(request({state_id: 3, view: 'invalid'}), dependencies);
assert.equal(invalid.status, 400);
assert.equal(calls.length, 0);

const forbidden = await handleProvinceProjection(request({state_id: 3, view: 'trade'}), dependencies);
assert.equal(forbidden.status, 403);
assert.equal(calls.length, 2);
assert.ok(calls.every(call => !call.url.includes('projection_source_api')));
assert.ok(calls.every(call => call.options.headers.authorization === 'Bearer test-token'));

const missingAuth = await handleProvinceProjection(new Request('https://local.example/projection', {
  method: 'POST', body: '{}',
}), dependencies);
assert.equal(missingAuth.status, 401);
assert.equal(calls.length, 2);
console.log('Projection adapter checks passed');
