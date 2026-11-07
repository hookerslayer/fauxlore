// Правило «нейтральный маркер»: у маркера нет государства, а провинция сухопутная.
// Тест читает реальный helper из viewer.js, поэтому ловит и расхождение
// клиентской подсветки со схемным ограничением колонизации.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../viewer.js', import.meta.url), 'utf8');
const match = source.match(/function neutralMarkersInProvince\(id\)\{[\s\S]*?\n\}/);
assert.ok(match, 'В viewer.js не найден helper neutralMarkersInProvince');

const markers = [
  { id: 1, province_id: 42, type: 'fortress', state_id: null },
  { id: 2, province_id: 42, type: 'port', state_id: undefined },
  { id: 3, province_id: 42, type: 'city', state_id: 5 },
  { id: 4, province_id: 43, type: 'fortress', state_id: null },
];
const context = { mapMarkers: markers };
vm.createContext(context);
vm.runInContext(match[0], context);
const neutralIn = vm.runInContext('neutralMarkersInProvince', context);

assert.equal(neutralIn(42).length, 2, 'Нейтральными считаются маркеры без государства');
assert.deepEqual(neutralIn(42).map(marker => marker.id), [1, 2]);
assert.equal(neutralIn(43).length, 1);
assert.equal(neutralIn(99).length, 0);

// Серверная проверка должна оставаться на месте: без неё клиентская
// подсветка станет ложью, а провинцию можно будет колонизировать.
const schema = fs.readFileSync(new URL('../supabase/schema.sql', import.meta.url), 'utf8');
assert.ok(
  schema.includes("from fauxlore.map_markers m where m.province_id=target_key and m.state_id is null"),
  'В colonization_api нет проверки нейтрального маркера',
);
assert.ok(
  schema.includes('military_port_builds_marker_id_fkey') && schema.includes('on delete cascade'),
  'Нет каскадного удаления порта вместе с маркером',
);
assert.ok(
  schema.includes('create or replace function fauxlore.military_delete_formation'),
  'Нет функции удаления пустого формирования',
);
console.log('PASS: нейтральные маркеры, блок колонизации и удаление маркера согласованы');
