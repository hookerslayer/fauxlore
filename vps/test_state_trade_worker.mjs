import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const worker = fileURLToPath(new URL('./province_worker.mjs', import.meta.url));
const state = {id: 5, name: 'Тест', principles: {authority: 'Магистрат', economy: 'Гильдии', structure: 'Ленное право', military: 'Гвардия'},
  crime: 0.2, corruption: 0.2, official_race: 'Люди', official_religion: 'Правоверие', form_name: 'Республика'};
const province = {id: 42, kind: 'land', province_type: 'Регион', population: 1000,
  development: 100, control: 100, trade_status: 'Отсутствует',
  layers: {states: {id: 5, name: 'Тест', crime: 0.2, corruption: 0.2,
    estate_tax_rates: {Знать: 10, Духовенство: 1, Горожане: 3, Крестьяне: 1}},
    races: {id: 1, name: 'Люди'}, religions: {id: 1, name: 'Правоверие'},
    resources: {name: 'Зерно'}, trade: {id: 1, name: 'Зона'}}};
const source = {data_revision: 7, live_revision: 9,
  economy_config: {resources: [{name: 'Зерно', category: 'Повседневные товары', value: 1, production: 0.5, consumption: 1, showInProduction: true}],
    provinceModifiers: {Регион: {production: 1}}, estateTaxRates: {Знать: 10, Духовенство: 1, Горожане: 3, Крестьяне: 1}},
  provinces: [province]};
const snapshot = {state_id: 5, view: 'trade', local_events: [], projection_source: source, routes: {
  'auth/me': {user: {role: 'player'}},
  'my/states': [state],
  'my/states/5/indicators': {permanent_modifiers: [], estate_loyalties: [], crime: 0.2, corruption: 0.2, stability: 0.5},
  'my/states/5/trade-overview': {year: 1, turn: 1, resources: [], zones: []},
  'my/states/5/trade-duty': {rate: 15, cost: 3},
  'my/states/5/estate-tax-rates': {groups: []},
  'my/trade-agreements': {agreements: [{status: 'accepted', from_state_id: 6, to_state_id: 5,
    terms: {from_goods: [{name: 'Зерно', quantity: 120}], to_goods: []}}]},
}};
const result = spawnSync(process.execPath, [worker], {input: JSON.stringify(snapshot), encoding: 'utf8', timeout: 15000});
assert.equal(result.status, 0, result.stderr);
const body = JSON.parse(result.stdout);
assert.equal(body.status, 200, JSON.stringify(body));
const grain = (body.body.resources || []).find(row => row.resource_name === 'Зерно');
assert.ok(grain, 'прогноз должен содержать зерно');
assert.equal(grain.contract_import, 120, 'прогноз берёт ввоз из действующего договора');
assert.equal(grain.zone_import, 0, 'зона без данных не добавляет ввоз');

// Старый снимок без маршрута договоров не должен ронять всю проекцию.
const withoutAgreements = structuredClone(snapshot);
delete withoutAgreements.routes['my/trade-agreements'];
const fallback = spawnSync(process.execPath, [worker], {input: JSON.stringify(withoutAgreements), encoding: 'utf8', timeout: 15000});
assert.equal(fallback.status, 0, fallback.stderr);
const fallbackBody = JSON.parse(fallback.stdout);
assert.equal(fallbackBody.status, 200, 'прогноз без договоров остаётся доступным');
console.log('State trade worker: forecast uses agreement terms and serves the trade view');
