// Конструктор событий выбирает провинцию кликом по карте, а не списком.
// Тест держит связку трёх файлов: local-events (кнопка и черновик),
// viewer (режим выбора и событие о выбранной провинции) и ui (переходы).
import fs from 'node:fs';
import assert from 'node:assert/strict';

const read = name => fs.readFileSync(new URL(`../${name}`, import.meta.url), 'utf8');
const events = read('local-events.js');
const viewer = read('viewer.js');
const ui = read('ui.js');

assert.ok(events.includes('data-pick-province'), 'Нет кнопки выбора провинции на карте');
assert.ok(!/<select name="province_id"/.test(events), 'Провинция всё ещё выбирается из списка');
assert.ok(events.includes('type="hidden" name="province_id"'), 'Нет скрытого поля провинции');
assert.ok(events.includes("'local-event:pick'"), 'Форма не включает режим выбора на карте');
assert.ok(events.includes("'local-event:province-picked'"), 'Форма не принимает выбранную провинцию');
assert.ok(events.includes('eventDraft'), 'Нет черновика, переживающего переход на карту');

assert.ok(viewer.includes("addEventListener('local-event:pick'"), 'Карта не включает режим выбора');
assert.ok(viewer.includes("'local-event:province-picked'"), 'Карта не сообщает выбранную провинцию');
assert.ok(viewer.includes('eventProvincePick'), 'Нет состояния режима выбора');

assert.ok(ui.includes("addEventListener('ui:show-map'"), 'Нет перехода на карту из панели');
assert.ok(ui.includes("addEventListener('ui:open-profile'"), 'Нет возврата к форме после выбора');
console.log('PASS: провинция для события выбирается кликом по карте');
