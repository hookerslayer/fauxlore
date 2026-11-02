import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const worker = fileURLToPath(new URL('./province_worker.mjs', import.meta.url));
const province = {id: 42, kind: 'land', province_type: 'Регион', population: 1000,
  development: 100, control: 100, trade_status: 'Отсутствует',
  layers: {states: {id: 5, name: 'Тест', crime: 0, corruption: 0,
    estate_tax_rates: {Знать: 10, Духовенство: 1, Горожане: 3, Крестьяне: 1}},
    races: {id: 1, name: 'Люди'}, religions: {id: 1, name: 'Правоверие'}, resources: {name: 'Зерно'}}};
const snapshot = {province_id: 42, local_events: [], routes: {
  map: {data_revision: 7, live_revision: 9, provinces: [province]},
  'auth/me': {user: {role: 'player'}},
  'my/states': [{id: 5, name: 'Тест', principles: {}}],
  'my/states/5/indicators': {permanent_modifiers: [], corruption: 0},
}};
function run(input) {
  const processResult = spawnSync(process.execPath, [worker], {input: JSON.stringify(input), encoding: 'utf8', timeout: 15000});
  assert.equal(processResult.status, 0, processResult.stderr);
  return JSON.parse(processResult.stdout);
}
const allowed = run(snapshot);
assert.equal(allowed.status, 200);
assert.equal(allowed.body.province_id, 42);
assert.equal(typeof allowed.body.taxes, 'number');
assert.equal(allowed.body.data_revision, 7);
const denied = structuredClone(snapshot);
denied.routes.map.provinces[0].layers.states.estate_tax_rates = null;
assert.equal(run(denied).status, 403);
const missing = structuredClone(snapshot);
missing.province_id = 43;
assert.equal(run(missing).status, 404);
console.log('Province worker: authorized calculation, forbidden access and missing province passed');
