// Нейтральные силы: серверная функция, клиентский RPC, панель администратора
// и включение модуля в публичную сборку должны существовать вместе.
import fs from 'node:fs';
import assert from 'node:assert/strict';

const read = name => fs.readFileSync(new URL(`../${name}`, import.meta.url), 'utf8');

const schema = read('supabase/schema.sql');
assert.ok(schema.includes('create or replace function fauxlore.neutral_forces_api'), 'Нет RPC нейтральных сил');
assert.ok(schema.includes('alter column state_id drop not null'), 'state_id всё ещё обязателен для формирований или гарнизонов');
assert.ok(schema.includes("'create_formation'") && schema.includes("'hire_unit'"), 'Нет создания формирований и юнитов');
assert.ok(schema.includes("'garrison_add'") && schema.includes("'garrison_remove'"), 'Нет управления нейтральными гарнизонами');
assert.ok(schema.includes('Neutral formation map join not found') && schema.includes("left join fauxlore.map_categories state on state.layer=''states'' and state.id=f.state_id"),
  'Нейтральные формирования не попадут на карту из-за inner join');

const client = read('vps-postgrest-client.js');
assert.ok(client.includes("'neutral_forces_api'"), 'RPC не разрешён в клиенте vps-postgrest');

const api = read('supabase-api.js');
assert.ok(api.includes('export async function neutralForcesApi'), 'Нет обёртки neutralForcesApi');

const ui = read('ui.js');
assert.ok(ui.includes('renderNeutralForces'), 'Панель не подключена к профилю администратора');
assert.ok(ui.includes('data-neutral-forces'), 'Нет секции панели в профиле');

const panel = read('neutral-forces-ui.js');
assert.ok(panel.includes("'garrison_add'"), 'Панель не заполняет гарнизоны');
assert.ok(panel.includes("'create_formation'"), 'Панель не создаёт формирования');

const build = read('tools/build_supabase_site.py');
assert.ok(build.includes("'neutral-forces-ui.js'"), 'Модуль не попадает в публичную сборку');
console.log('PASS: нейтральные силы связаны от схемы до панели администратора');
