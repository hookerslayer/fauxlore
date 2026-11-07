// Откат строительства: серверная функция возврата, RPC, панель и сборка.
import fs from 'node:fs';
import assert from 'node:assert/strict';

const read = name => fs.readFileSync(new URL(`../${name}`, import.meta.url), 'utf8');
const schema = read('supabase/schema.sql');

assert.ok(schema.includes('create or replace function fauxlore.admin_rollback_api'), 'Нет RPC отката');
assert.ok(schema.includes('create or replace function fauxlore.refund_state_cash'), 'Нет функции возврата денег');
assert.ok(schema.includes("'admin_refund'"), 'Возврат не пишется в журнал бюджета');
assert.ok(schema.includes('grant execute on function fauxlore.admin_rollback_api'), 'RPC недоступен вошедшим пользователям');
assert.ok(schema.includes("'cancel_port_project'") && schema.includes("'cancel_port'") && schema.includes("'cancel_garrison_project'"),
  'Нет отмены порта, сноса порта или отмены укрепления');

const client = read('vps-postgrest-client.js');
assert.ok(client.includes("'admin_rollback_api'"), 'RPC не разрешён в клиенте vps-postgrest');

const api = read('supabase-api.js');
assert.ok(api.includes('export async function adminRollbackApi'), 'Нет обёртки adminRollbackApi');

const ui = read('ui.js');
assert.ok(ui.includes('renderAdminRollback') && ui.includes('data-admin-rollback'), 'Панель отката не подключена к профилю');

const panel = read('admin-rollback-ui.js');
assert.ok(panel.includes("'cancel_port_project'"), 'Панель не отменяет строительство порта');
assert.ok(panel.includes("'cancel_port'"), 'Панель не сносит построенный порт');

const build = read('tools/build_supabase_site.py');
assert.ok(build.includes("'admin-rollback-ui.js'"), 'Модуль не попадает в публичную сборку');
console.log('PASS: откат строительства с компенсацией связан от схемы до панели');
