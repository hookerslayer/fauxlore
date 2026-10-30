import {militaryApi,militaryBattleApi,navalBattlePreviewApi,militaryTransportApi,militarySiegeApi,militarySiegeStormApi,militiaApi,garrisonApi} from './supabase-api.js?v=server-boundary-final-20261030';
import {renderGarrisonPanel} from './garrison-ui.js?v=server-boundary-final-20261030';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=value=>Math.floor(Number(value)||0).toLocaleString('ru-RU');
const money=value=>Number(value||0).toLocaleString('ru-RU',{maximumFractionDigits:2});
const factor=value=>Number(value||0).toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2});
const domains={land:'Сухопутные',naval:'Морские',siege:'Осадные'};
const relations={own:'Своё государство',peace:'Мир',justified_war:'Оправданная война',unjustified_war:'Неоправданная война'};
const status={pending:'Ожидает ответа',awaiting_admin:'На рассмотрении судьи',accepted:'Действует',rejected:'Отклонено',ended:'Расторгнуто'};
const kinds={war:'Объявление войны',peace:'Заключение мира',passage:'Право прохода'};
export const casusBelli=['Завоевание','Священная война','Реконкиста','Торговый спор','Оскорбление чести','Династическая уния','Поддержка повстанцев','Ликвидация угрозы','Поддержка союзника','Война без Casus Belli, Король так захотел!'];
let activeMilitaryTab='Обзор';

async function run(host,action,stateId,payload,notify,refresh){
  const buttons=[...host.querySelectorAll('button')];buttons.forEach(button=>button.disabled=true);
  try{const result=await militaryApi(action,stateId,payload);window.dispatchEvent(new Event('state:resources-changed'));window.dispatchEvent(new Event('map:refresh'));notify?.('Действие выполнено');await refresh();return result;}
  catch(error){notify?.(error.message);buttons.forEach(button=>button.disabled=false);return null;}
}

export async function renderMilitaryPanel(host,{stateId,notify,onMapChange}={}){
  if(!host)return;
  const alreadyRendered=Boolean(host.querySelector('.state-menu'));
  const openFormationId=host.querySelector('.military-formation-dialog[open]')?.dataset.formationDialog;
  if(!alreadyRendered)host.innerHTML='<p class="hint">Загружаю военное дело…</p>';
  try{
    const [data,militia,garrisons,siegeData]=await Promise.all([militaryApi('snapshot',stateId),militiaApi('snapshot',stateId),garrisonApi('snapshot',stateId),militarySiegeApi(stateId)]);
    if(!host.isConnected)return;
    const refresh=()=>renderMilitaryPanel(host,{stateId,notify,onMapChange});
    const tabs=['Обзор','Армии и флот','Сражения','Осады','Гарнизоны','Ополчение','Наёмники','Полководцы','Каталог'];
    if(activeMilitaryTab==='Найм')activeMilitaryTab='Обзор';
    if(activeMilitaryTab==='Командиры')activeMilitaryTab='Полководцы';
    if(!tabs.includes(activeMilitaryTab))activeMilitaryTab='Обзор';
    const provinceName=id=>data.provinces.find(p=>Number(p.id)===Number(id))?.name||`№ ${id}`;
    const provinceNeighbors=province=>Array.isArray(province?.neighbors)?province.neighbors.map(Number):[];
    const ownedCities=data.provinces.filter(p=>p.kind==='land'&&p.owned&&(p.city||p.capital));
    const ports=data.provinces.filter(p=>p.kind==='sea'&&p.port);
    const placesFor=domain=>domain==='naval'?ports:ownedCities;
    const regular=data.formations.filter(f=>f.kind==='regular');
    const compositionControls=f=>{
      if(f.kind!=='regular')return '';
      const unitOptions=f.units.map(unit=>`<option value="${Number(unit.unit_id)}" data-quantity="${Number(unit.quantity)}">${escape(unit.name)} · ${fmt(unit.quantity)}</option>`).join('');
      const targets=regular.filter(other=>Number(other.id)!==Number(f.id)&&other.domain===f.domain&&Number(other.province_id)===Number(f.province_id));
      const targetOptions=targets.map(other=>`<option value="${Number(other.id)}">${escape(other.name)}</option>`).join('');
      if(!f.units.length)return '<p class="hint">В формировании нет частей.</p>';
      const splitName=`${f.name} — отделение`.slice(0,100);
      const totalUnits=Number(f.units.reduce((n,u)=>n+Number(u.quantity),0));
      const splitMax=Math.min(Number(f.units[0].quantity),Math.max(0,totalUnits-1));
      return `<div class="military-composition-controls"><p class="hint">Передавать состав и объединять можно только с формированиями того же типа в этой же провинции. Флоты в колонизационной миссии временно заблокированы.</p><form class="inline-actions" data-composition-split="${Number(f.id)}" data-total-units="${totalUnits}"><strong>Разделить</strong><select name="unit_id" data-composition-unit aria-label="Части для выделения">${unitOptions}</select><input name="quantity" type="number" min="1" max="${splitMax}" value="1" aria-label="Количество частей для выделения"><input name="name" minlength="2" maxlength="100" required value="${escape(splitName)}" aria-label="Название нового формирования"><button type="submit" ${totalUnits<2?'disabled':''}>Выделить в новое</button></form>${targets.length?`<form class="inline-actions" data-composition-transfer="${Number(f.id)}"><strong>Перевести часть состава</strong><select name="unit_id" data-composition-unit aria-label="Тип передаваемых частей">${unitOptions}</select><input name="quantity" type="number" min="1" max="${Number(f.units[0].quantity)}" value="1" aria-label="Количество передаваемых частей"><select name="target_formation_id" aria-label="Куда перевести части">${targetOptions}</select><button type="submit">Перевести</button></form><form class="inline-actions" data-composition-merge="${Number(f.id)}"><strong>Объединить с</strong><select name="target_formation_id" aria-label="Целевое формирование">${targetOptions}</select><button type="submit">Объединить</button></form>`:'<p class="hint">Для перевода состава или объединения создайте вторую армию или флотилию этого же типа в этой провинции.</p>'}</div>`;
    };
    const leaders=data.leaders,activeLeaders=leaders.filter(l=>l.status==='active');
    const generals=leaders.filter(l=>l.domain==='land').length,admirals=leaders.filter(l=>l.domain==='naval').length;
    const upkeepBreakdown=data.upkeep_breakdown||{};
    const armyUpkeep=Number(upkeepBreakdown.army||0),fleetUpkeep=Number(upkeepBreakdown.fleet||0);
    const militiaUpkeep=Number(upkeepBreakdown.militia||0),mercenaryUpkeep=Number(upkeepBreakdown.mercenaries||0);
    const upkeep=Number(upkeepBreakdown.total||0);
    const catalogTable=domain=>`<section class="application-panel"><h4>${domains[domain]}</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Юнит</th><th>Категория</th><th>Здоровье</th><th>Урон</th><th>Броня</th><th>Инициатива</th><th>Рекруты</th><th>Цена</th><th>Содержание</th><th>Условие</th></tr></thead><tbody>${data.catalog.filter(u=>u.domain===domain).map(u=>`<tr><td>${escape(u.name)}</td><td>${escape(u.category)}</td><td>${u.health}</td><td>${u.damage}${u.charge_damage?` (${u.charge_damage})`:''}</td><td>${u.armor}</td><td>${u.initiative}</td><td>${u.recruit_cost}</td><td>${fmt(u.hire_price)}</td><td>${fmt(u.upkeep_price)}</td><td>${u.prerequisite==='saltpeter'?'Избыток селитры':'—'}</td></tr>`).join('')}</tbody></table></div></section>`;
    const locationOptions=domain=>placesFor(domain).map(p=>`<option value="${p.id}">${escape(p.name)}${p.port?' · порт':''}</option>`).join('');
    const hiringRows=data.catalog.filter(u=>u.hireable).map(unit=>{
      const domain=unit.domain==='naval'?'naval':'land',placeList=placesFor(domain),matching=regular.filter(f=>f.domain===domain);
      const formationOptions=matching.map(f=>`<option value="${f.id}" data-province="${f.province_id}">${escape(f.name)}</option>`).join('');
      return `<tr><td data-label="Юнит"><strong>${escape(unit.name)}</strong></td><td data-label="Категория">${escape(unit.category)}</td><td data-label="Цена за часть">${fmt(unit.hire_price)} G</td><td data-label="Содержание / ход">${fmt(unit.upkeep_price)} G</td><td data-label="Рекруты / часть">${fmt(unit.recruit_cost)}</td><td data-label="Место"><form class="military-hire-row" data-hire-unit="${unit.id}"><select name="province_id" aria-label="Место найма" required ${placeList.length?'':'disabled'}>${locationOptions(domain)}</select></form></td><td data-label="Формирование"><select form="" name="formation_id" aria-label="Формирование"><option value="">Новое</option>${formationOptions}</select></td><td data-label="Количество"><input form="" name="quantity" type="number" min="1" max="100000" step="1" value="1" aria-label="Количество" ${placeList.length?'':'disabled'}></td><td data-label="Итого"><span data-hire-estimate>${fmt(unit.hire_price)} G · ${fmt(unit.recruit_cost)} рекр.</span></td><td data-label="Действие"><button type="submit" form="" class="primary" data-hire-submit="${unit.id}" ${placeList.length?'':'disabled'}>Нанять</button></td></tr>`;
    }).join('');
    const hirePanel=`<section class="application-panel"><h4>Найм регулярной армии</h4><p class="hint">Выберите провинцию, при желании — существующее формирование, укажите количество и нажмите «Нанять».</p><div class="table-scroll"><table class="state-data-table military-hiring-table"><thead><tr><th>Название</th><th>Категория</th><th>Цена за часть</th><th>Содержание / ход</th><th>Рекруты / часть</th><th>Место</th><th>Формирование</th><th>Количество</th><th>Итого</th><th></th></tr></thead><tbody>${hiringRows||'<tr><td colspan="10">Нет доступных для найма частей.</td></tr>'}</tbody></table></div></section>`;
    const expenseRows=[['Армия',money(armyUpkeep)],['Флот',money(fleetUpkeep)],['Ополчение',money(militiaUpkeep)],['Наёмники',money(mercenaryUpkeep)],['Крепости',money(garrisons.fortification_upkeep)],['Гарнизоны',money(garrisons.troop_upkeep)]].map(([label,value])=>`<div><span>${label}</span><strong>${value} G</strong></div>`).join('');
    const overview=`<div class="military-overview"><aside class="military-overview-side"><section class="state-dashboard-card"><h4>Традиции</h4><p>Военные <strong>${fmt(data.traditions?.land)}%</strong></p><p>Морские <strong>${fmt(data.traditions?.naval)}%</strong></p></section><section class="state-dashboard-card"><h4>Рекруты</h4><p>Доступно <strong>${fmt(data.recruits)}</strong></p><p>Лимит <strong>${fmt(data.recruitment?.recruit_limit)}</strong></p><p>Прирост / ход <strong>${fmt(data.recruitment?.recruit_growth)}</strong></p></section><section class="state-dashboard-card"><h4>Полководцы</h4><p>Доступно <strong>${fmt(Math.max(0,Number(data.leader_limit||0)-leaders.length))}</strong></p><p>Лимит <strong>${fmt(data.leader_limit)}</strong></p><p>Генералы <strong>${generals}</strong></p><p>Адмиралы <strong>${admirals}</strong></p></section><section class="state-dashboard-card"><h4>Расходы / ход</h4>${expenseRows}<p>Всего <strong>${money(upkeep)} G</strong></p></section></aside><div class="military-overview-main">${hirePanel}</div></div>`;
    const formationRows=data.formations.map((f,formationIndex)=>{
      const units=f.units.length?f.units:[null],leaderOptions=activeLeaders.filter(l=>l.domain===f.domain).map(l=>`<option value="${l.id}" ${Number(f.leader_id)===Number(l.id)?'selected':''}>${escape(l.name)}</option>`).join('');
      const heading=`<tr class="military-formation-heading"><th colspan="7"><div class="military-formation-heading-content"><form class="military-rename-formation" data-rename-formation="${f.id}"><input name="name" maxlength="100" minlength="2" required value="${escape(f.name)}" aria-label="Название формирования"><button type="submit">Сохранить</button></form>${f.kind==='regular'?`<button type="button" class="military-manage-formation" data-open-formation="${Number(f.id)}">Управление</button>`:''}</div></th></tr>`;
      const separator=formationIndex?'<tr class="military-formation-gap"><td colspan="7"></td></tr>':'';
      const fleet=data.formations.find(item=>Number(item.id)===Number(f.transported_by));
      const location=fleet?`На борту «${escape(fleet.name)}»`:escape(provinceName(f.province_id));
      return separator+heading+units.map((unit,index)=>`<tr>${index===0?`<td rowspan="${units.length}">${location}</td><td rowspan="${units.length}">${f.kind==='regular'?`<select data-assign-leader="${f.id}"><option value="">Без полководца</option>${leaderOptions}</select>`:'—'}</td>`:''}<td>${unit?escape(unit.name):'—'}</td><td>${unit?escape(domains[data.catalog.find(c=>Number(c.id)===Number(unit.unit_id))?.domain]||'Часть'):'—'}</td><td>${unit?fmt(unit.quantity):'—'}</td><td>${unit?fmt(unit.unit_upkeep):'—'}${unit?' G':''}</td><td>${unit?fmt(f.kind==='mercenary'&&index===0?Number(data.mercenaries.find(g=>Number(g.id)===Number(f.mercenary_group_id))?.upkeep_price??0):Number(unit.total_upkeep||0)):'—'}${unit?' G':''}</td></tr>`).join('');
    }).join('');
    const formationDialogs=regular.map(f=>{
      const fleet=data.formations.find(item=>Number(item.id)===Number(f.transported_by));
      const neighbors=provinceNeighbors(data.provinces.find(p=>Number(p.id)===Number(f.province_id)));
      const availableFleets=regular.filter(item=>item.domain==='naval'&&!item.movement_order&&!item.colonization_mission_id&&data.provinces.find(p=>Number(p.id)===Number(item.province_id))?.port&&neighbors.includes(Number(item.province_id)));
      const passengers=regular.filter(item=>Number(item.transported_by)===Number(f.id));
      const landings=data.provinces.filter(p=>p.kind==='land'&&p.controlled&&provinceNeighbors(data.provinces.find(x=>Number(x.id)===Number(f.province_id))).includes(Number(p.id)));
      const nearbyArmies=regular.filter(item=>item.domain==='land'&&!item.transported_by&&provinceNeighbors(data.provinces.find(p=>Number(p.id)===Number(item.province_id))).includes(Number(f.province_id)));
      const transport=f.domain==='land'?(fleet?`<form class="inline-actions" data-transport-action="disembark" data-army="${Number(f.id)}" data-fleet="${Number(fleet.id)}"><span>На борту «${escape(fleet.name)}»</span><select name="target_province" required aria-label="Провинция высадки">${landings.map(p=>`<option value="${Number(p.id)}">${escape(p.name)}</option>`).join('')}</select><button type="submit" ${landings.length?'':'disabled'}>Высадить</button></form>`:availableFleets.length?`<form class="inline-actions" data-transport-action="embark" data-army="${Number(f.id)}"><span>Погрузка из провинции «${escape(provinceName(f.province_id))}»</span><select name="fleet_id" required aria-label="Флотилия для погрузки">${availableFleets.map(item=>`<option value="${Number(item.id)}">${escape(item.name)} · ${escape(provinceName(item.province_id))}</option>`).join('')}</select><button type="submit">Погрузить на флот</button></form>`:'<p class="hint">Погрузка доступна, когда флот находится в доступном порту у этой провинции.</p>'):
        `<p class="hint">Вместимость: 100 рекрутских очков на единицу вместимости. Армии на борту движутся вместе с флотом.</p>${nearbyArmies.length?`<form class="inline-actions" data-transport-action="embark" data-fleet="${Number(f.id)}"><span>Погрузить армию</span><select name="army_id" required aria-label="Армия для погрузки">${nearbyArmies.map(item=>`<option value="${Number(item.id)}">${escape(item.name)} · ${escape(provinceName(item.province_id))}</option>`).join('')}</select><button type="submit">Погрузить</button></form>`:'<p class="hint">Рядом нет свободных армий для погрузки.</p>'}${passengers.map(army=>`<form class="inline-actions" data-transport-action="disembark" data-army="${Number(army.id)}" data-fleet="${Number(f.id)}"><strong>${escape(army.name)}</strong><select name="target_province" required aria-label="Провинция высадки">${landings.map(p=>`<option value="${Number(p.id)}">${escape(p.name)}</option>`).join('')}</select><button type="submit" ${landings.length?'':'disabled'}>Высадить</button></form>`).join('')||'<p class="hint">На борту нет армий.</p>'}`;
      return `<dialog class="military-formation-dialog" data-formation-dialog="${Number(f.id)}"><div class="modal-shell"><header><div><p class="hint">${f.domain==='naval'?'Флотилия':'Армия'} · ${escape(provinceName(fleet?.province_id??f.province_id))}</p><h3>${escape(f.name)}</h3></div><button type="button" class="icon-button" data-close-formation aria-label="Закрыть">×</button></header><div class="military-formation-dialog-content">${f.kind==='regular'?`<section class="military-composition-controls"><h4>Состав и перемещение частей</h4>${compositionControls(f)}</section>`:''}<section class="military-composition-controls"><h4>Погрузка и высадка</h4>${transport}</section><p class="form-message" data-formation-message aria-live="polite"></p></div></div></dialog>`;
    }).join('');
    const formationTable=`<section class="application-panel"><h4>Создать армию или флотилию</h4><form class="inline-actions military-create-formation"><select name="domain" aria-label="Тип формирования"><option value="land">Армия</option><option value="naval">Флотилия</option></select><input name="name" minlength="2" maxlength="100" required placeholder="Название формирования"><select name="province_id" data-create-location required aria-label="Место базирования"><option value="" data-domain="land">${ownedCities.length?'Выберите город':'Нет своего города с маркером'}</option>${ownedCities.map(p=>`<option value="${p.id}" data-domain="land">${escape(p.name)}</option>`).join('')}<option value="" data-domain="naval">${ports.length?'Выберите порт':'Нет доступных портов'}</option>${ports.map(p=>`<option value="${p.id}" data-domain="naval">${escape(p.name)} · порт</option>`).join('')}</select><button type="submit" class="primary">Создать</button></form></section><section class="application-panel"><h4>Армии и флотилии</h4><div class="table-scroll"><table class="state-data-table military-formations-table"><thead><tr><th>Местоположение</th><th>Генерал / адмирал</th><th>Название юнита</th><th>Тип юнита</th><th>Количество</th><th>Содержание</th><th>Расходы</th></tr></thead><tbody>${formationRows||'<tr><td colspan="7">Формирований пока нет.</td></tr>'}</tbody></table></div></section>${formationDialogs}`;
    const battleRows=(data.battles||[]).map(b=>{
      const sides=[...new Map((b.participants||[]).map(p=>[Number(p.state_id),p])).values()];
      const siegeAssault=(b.participants||[]).map(p=>p.siege_assault).find(Boolean);
      const navalOptions=b.domain==='naval'&&sides.length===2?`<section class="state-dashboard-card" data-naval-options="${Number(b.id)}"><h5>Морской калькулятор · настройки судьи</h5><label class="field"><span>Атакующий флот</span><select data-naval-attacker>${sides.map(p=>`<option value="${Number(p.state_id)}">${escape(p.state_name)}</option>`).join('')}</select></label><label><input type="checkbox" data-poor-visibility> Плохая видимость</label>${sides.map((p,index)=>`<fieldset><legend>${escape(p.state_name)}</legend><label><input type="checkbox" data-naval-option="withdraw" data-state="${Number(p.state_id)}"> Попытка отхода до боя</label><label><input type="checkbox" data-naval-option="safe" data-state="${Number(p.state_id)}"> Есть безопасный путь отхода</label><label><input type="checkbox" data-naval-option="adverse" data-state="${Number(p.state_id)}"> Неблагоприятные условия</label><label><input type="checkbox" data-naval-option="pursue" data-state="${Number(p.state_id)}"> Приказ преследовать</label></fieldset>`).join('')}<button type="button" data-calc-naval="${Number(b.id)}">Рассчитать морской бой</button><p class="hint" data-naval-report aria-live="polite">Расчёт ещё не выполнен.</p></section>`:'';
      const siegeBrief=siegeAssault?`<section class="state-dashboard-card"><h5>Штурм укрепления</h5><p>Способ атаки: ${escape(siegeAssault.route_label)} · множитель атаки ×${factor(siegeAssault.attack_multiplier)}</p><p>Укрепление ${siegeAssault.fortification_state==='breached'?'пробито':'целое'}, уровень ${fmt(siegeAssault.fortification_level)} · множитель защиты гарнизона ×${factor(siegeAssault.defense_multiplier)}</p><p class="hint">Учитывайте эти множители при ручном определении исхода и потерь.</p></section>`:'';
      const judgeForm=data.is_admin?`<form class="stack" data-resolve-battle="${Number(b.id)}"><h5>Решение судьи</h5>${siegeBrief}${navalOptions}<label class="field"><span>Победитель</span><select name="winner_state_id" required>${sides.map(p=>`<option value="${Number(p.state_id)}">${escape(p.state_name)}</option>`).join('')}</select></label><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Государство / формирование</th><th>Часть</th><th>${b.domain==='naval'?'Потери судов':'Потери'}</th></tr></thead><tbody>${(b.participants||[]).map(p=>(p.units||[]).map((u,index)=>`<tr><td>${index===0?`${escape(p.state_name)} · ${escape(p.formation_name)}${p.kind==='garrison'?(siegeAssault?' · укреплённый гарнизон':' · гарнизон'):''}`:''}</td><td>${escape(u.name)} · ${fmt(u.quantity)}</td><td><input type="number" name="loss_${Number(p.formation_id)}_${Number(u.unit_id)}" min="0" max="${Number(u.quantity)}" value="0" aria-label="Потери: ${escape(u.name)}"></td></tr>`).join('')).join('')}</tbody></table></div><p class="hint">Для проигравших полевых формирований укажите провинцию отхода; гарнизон остаётся в укреплении.</p><div class="inline-actions">${(b.participants||[]).filter(p=>p.kind!=='garrison').map(p=>`<label class="field"><span>${escape(p.state_name)} · ${escape(p.formation_name)} — отход</span><select name="retreat_${Number(p.formation_id)}" data-retreat-state="${Number(p.state_id)}"><option value="">Выберите провинцию</option>${(b.retreat_options||[]).map(o=>`<option value="${Number(o.id)}">${escape(o.name)}</option>`).join('')}</select></label>`).join('')}</div><p class="hint">${b.domain==='naval'?'Подтверждение применит рассчитанные потери и состояние кораблей; погружённые армии проигравшего флота погибают.':siegeAssault?'Победа атакующих передаёт контроль и укрепление; победа защитников снимает эту осаду.':'Контроль суши переходит победителю.'}</p><button type="submit" class="primary">Зафиксировать исход</button></form>`:'';
      return `<article class="marriage-candidate"><strong>${siegeAssault?'Штурм укрепления':b.domain==='naval'?'Морское столкновение':'Сухопутное сражение'} · ${escape(b.province_name||provinceName(b.province_id))}</strong><p>Ход ${fmt(b.turn)}, ${fmt(b.year)} год · Ожидает решения судьи</p><p>Формирования остановлены до завершения сражения.</p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Государство</th><th>Формирование</th><th>Состав</th></tr></thead><tbody>${(b.participants||[]).map(p=>`<tr><td>${escape(p.state_name)}</td><td>${escape(p.formation_name)}</td><td>${(p.units||[]).map(u=>`${escape(u.name)} × ${fmt(u.quantity)}`).join(', ')||'—'}</td></tr>`).join('')}</tbody></table></div>${judgeForm}</article>`;
    }).join('');
    const battlePanel=`<section class="application-panel"><h4>Военные столкновения</h4>${battleRows||'<p class="hint">Незавершённых сражений нет.</p>'}${(data.battles||[]).length&&!data.is_admin?'<p class="hint">Решение и потери фиксирует судья. Участники не могут отдавать новые приказы движения до решения.</p>':''}</section>`;
    const content={
      'Обзор':overview,
      'Армии и флот':formationTable,
      'Сражения':battlePanel,
      'Осады':`<section class="application-panel"><h4>Осады и осадные фазы</h4>${(siegeData.sieges||[]).length?`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Провинция</th><th>Стороны</th><th>Состояние</th><th>Прогресс</th><th>Брешь</th><th>Фаза последнего хода</th>${data.is_admin?'<th>Действие</th>':''}</tr></thead><tbody>${siegeData.sieges.map(s=>{const latest=(s.phase_log||[]).slice(-4),actions=data.is_admin&&s.status==='active'?(s.assault_battle_id?'<span class="hint">Штурм ожидает решения во вкладке «Сражения»</span>':`<form class="inline-actions" data-siege-assault="${Number(s.province_id)}"><select name="route" aria-label="Способ штурма"><option value="ladders">Лестницы · ×0,75</option>${s.attacker_has_tower?'<option value="tower">Осадная башня · ×0,90</option>':''}${s.breached?'<option value="breach">Через пролом · ×1,00</option>':''}${s.attacker_has_ram?`<option value="ram">Таран · ×${s.breached?'1,00':'0,85'}</option>`:''}</select><button type="submit">Начать штурм</button></form>`):'—';return `<tr><td>${escape(s.province_name)}</td><td>${escape(s.attacker_name)} → ${escape(s.defender_name)}</td><td>${s.status==='active'?'Идёт':s.status==='capitulated'?'Капитуляция':'Снята'}</td><td>${fmt(s.progress)}%</td><td>${s.breached?'Пролом':'—'}</td><td>${latest.map(p=>`Ф${fmt(p.season_phase)}: +${fmt(p.progress_gain)}, −${fmt(p.garrison_losses)}; d10 ${fmt(p.d10)}`).join(' · ')||'—'}</td>${data.is_admin?`<td>${actions}</td>`:''}</tr>`;}).join('')}</tbody></table></div>`:'<p class="hint">Осады не начинались.</p>'}<p class="hint">Смена хода автоматически проводит четыре сезонные фазы. Потери гарнизона округляются вверх пропорционально приросту прогресса. Судья запускает штурм и вручную фиксирует его исход, потери и отход.</p></section>`,
      'Гарнизоны':`<div data-garrison-panel></div>`,
      'Ополчение':`<div data-militia-panel></div>`,
      'Наёмники':`<section class="application-panel"><h4>Доступные группы</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Город</th><th>Группа</th><th>Лидер и навыки</th><th>Состав</th><th>Найм</th><th>Цена за ход</th><th></th></tr></thead><tbody>${data.mercenaries.map(g=>`<tr><td>${escape(provinceName(g.city_province_id))}</td><td>${escape(g.name)}</td><td>${escape(g.leader_name)} · ${escape(JSON.stringify(g.leader_skills||{}))}</td><td>${(g.composition||[]).map(item=>`${escape(data.catalog.find(u=>Number(u.id)===Number(item.unit_id))?.name||item.unit_id)} × ${fmt(item.quantity)}`).join(', ')}</td><td>${fmt(g.hire_price??g.price)} G</td><td>${fmt(g.upkeep_price??g.price)} G</td><td>${g.hired_by?'Наняты':`<button data-hire-mercenary="${g.id}">Нанять</button>`}</td></tr>`).join('')}</tbody></table></div></section>${data.is_admin?`<section class="application-panel"><h4>Конструктор наёмников</h4><form data-mercenary-create class="stack"><label class="field"><span>Название группы</span><input name="name" required maxlength="100"></label><label class="field"><span>Лидер</span><input name="leader_name" required maxlength="100"></label><label class="field"><span>Навыки лидера</span><input name="leader_skills" placeholder="Натиск 2, Огонь 1"></label><label class="field"><span>Город базирования</span><select name="city_province_id">${data.provinces.filter(p=>p.city||p.capital).map(p=>`<option value="${p.id}">${escape(p.name)}</option>`).join('')}</select></label><label class="field"><span>Тип войск</span><select name="unit_id">${data.catalog.filter(u=>u.domain==='land').map(u=>`<option value="${u.id}">${escape(u.name)}</option>`).join('')}</select></label><label class="field"><span>Количество</span><input name="quantity" type="number" min="1" value="100" required></label><label class="field"><span>Цена</span><input name="price" type="number" min="0" value="1000" required></label><button type="submit">Создать группу</button></form></section>`:''}`,
      'Полководцы':`<section class="application-panel"><h4>Генералы и адмиралы</h4>${data.leaders.map(l=>`<p><strong>${escape(l.name)}</strong> · ${l.domain==='naval'?'Адмирал':'Генерал'} · ${escape(l.estate)} · Ур. ${l.level} · ${escape(Object.entries(l.skills||{}).map(([k,v])=>`${k} ${v}`).join(', '))}</p>`).join('')||'<p class="hint">Полководцев пока нет.</p>'}</section><section class="application-panel"><h4>Нанять полководца</h4><p class="hint">Базовая цена 2 500 G, 10 ОП и 5% соответствующей традиции. Сервер бросает кубики и записывает результат.</p><form data-hire-leader class="stack"><label class="field"><span>Имя</span><input name="name" required maxlength="100"></label><label class="field"><span>Роль</span><select name="domain"><option value="land">Генерал</option><option value="naval">Адмирал</option></select></label><label class="field"><span>Сословие</span><select name="estate">${['Знать','Духовенство','Горожане','Крестьяне'].map(x=>`<option>${x}</option>`).join('')}</select></label><button type="submit">Нанять полководца</button></form></section>`,
      'Каталог':Object.keys(domains).map(catalogTable).join('')+(data.is_admin?`<section class="application-panel"><h4>Добавить национальный тип войск</h4><p class="hint">Новая версия типа заменит старую в каталоге; уже нанятые юниты сохранят прежние характеристики.</p><form data-admin-unit class="stack"><label class="field"><span>Название</span><input name="name" required minlength="2" maxlength="80"></label><label class="field"><span>Род войск</span><select name="domain"><option value="land">Сухопутные</option><option value="naval">Морские</option><option value="siege">Осадные</option></select></label><label class="field"><span>Категория</span><input name="category" required></label>${[['health','Здоровье',10],['damage','Урон',1],['armor','Броня',1],['initiative','Инициатива',1],['recruit_cost','Рекруты',1],['hire_cost','Цена G',10],['upkeep','Содержание G',1],['power', 'Мощь',1],['capacity','Вместимость',0]].map(([name,label,value])=>`<label class="field"><span>${label}</span><input name="${name}" type="number" min="0" value="${value}" required></label>`).join('')}<label class="field"><span>Натиск</span><input name="charge_damage" type="number" min="0"></label><label class="field"><span>Условие</span><select name="prerequisite"><option value="none">Нет</option><option value="saltpeter">Избыток селитры</option></select></label><button type="submit">Сохранить юнит</button></form></section>`:''),
    };
    const page=host.closest('.app-page'),scrollTop=page?.scrollTop??0;
    const tableScrollLeft=host.querySelector('.military-overview-main .table-scroll')?.scrollLeft??0;
    host.innerHTML=`<div class="state-menu stack"><nav class="state-subtabs" aria-label="Военное дело">${tabs.map(tab=>`<button type="button" data-military-tab="${escape(tab)}" class="${tab===activeMilitaryTab?'active':''}" ${tab===activeMilitaryTab?'aria-current="page"':''}>${escape(tab)}</button>`).join('')}</nav><div class="stack">${content[activeMilitaryTab]}</div></div>`;
    if(alreadyRendered&&page)page.scrollTop=scrollTop;
    const hiringScroll=host.querySelector('.military-overview-main .table-scroll');if(hiringScroll)hiringScroll.scrollLeft=tableScrollLeft;
    host.querySelectorAll('[data-siege-assault]').forEach(form=>form.addEventListener('submit',event=>{
      event.preventDefault();
      const provinceId=Number(form.dataset.siegeAssault),route=form.elements.route.value,button=form.querySelector('button[type="submit"]');
      button.disabled=true;
      void (async()=>{try{const result=await militarySiegeStormApi(provinceId,route);notify?.(`Штурм начат. Сражение №${fmt(result.battle_id)} ожидает решения во вкладке «Сражения».`);window.dispatchEvent(new Event('map:refresh'));await refresh();}
        catch(error){notify?.(error.message);button.disabled=false;}})();
    }));
    host.querySelectorAll('[data-calc-naval]').forEach(button=>button.addEventListener('click',async()=>{
      const battle=(data.battles||[]).find(item=>Number(item.id)===Number(button.dataset.calcNaval));
      const form=host.querySelector(`[data-resolve-battle="${Number(button.dataset.calcNaval)}"]`);
      const options=host.querySelector(`[data-naval-options="${Number(button.dataset.calcNaval)}"]`);
      const report=options?.querySelector('[data-naval-report]');
      if(!battle||!form||!options)return;
      button.disabled=true;if(report)report.textContent='Сервер рассчитывает бой…';
      try{
        const stateIds=[...new Set(battle.participants.map(p=>Number(p.state_id)))];
        const attackerId=Number(options.querySelector('[data-naval-attacker]').value);
        const checked=kind=>Object.fromEntries(stateIds.map(id=>[String(id),Boolean(options.querySelector(`[data-naval-option="${kind}"][data-state="${id}"]`)?.checked)]));
        const result=await navalBattlePreviewApi(Number(battle.id),{
          attacker_state_id:attackerId,poor_visibility:Boolean(options.querySelector('[data-poor-visibility]')?.checked),
          safe:checked('safe'),adverse:checked('adverse'),withdraw:checked('withdraw'),pursue:checked('pursue')});
        if(!form.isConnected)return;
        form.elements.winner_state_id.disabled=false;
        if(result.winner_state_id){form.elements.winner_state_id.value=String(result.winner_state_id);form.elements.winner_state_id.disabled=true;}
        for(const loss of result.losses||[]){const input=form.elements[`loss_${loss.formation_id}_${loss.unit_id}`];if(input)input.value=String(loss.losses);}
        form.dataset.navalStates=JSON.stringify(result.naval_states||[]);
        form.dataset.navalCaptures=JSON.stringify(result.naval_captures||[]);
        form.dataset.navalReport=JSON.stringify(result.naval_report||null);
        form.querySelectorAll('input[name^="loss_"]').forEach(input=>input.readOnly=true);
        const outcomeText=result.winner_state_id?`Победитель: ${battle.participants.find(p=>Number(p.state_id)===Number(result.winner_state_id))?.state_name||'—'}`:'Ничья';
        if(report)report.textContent=`${outcomeText}. ${result.summary||''}${result.naval_report?.pursuit?.success?' Успешное преследование нанесло дополнительные потери.':''}`;
        button.textContent='Пересчитать с теми же настройками';
      }catch(error){if(report)report.textContent=error.message;}
      finally{if(button.isConnected)button.disabled=false;}
    }));
    host.querySelectorAll('[data-resolve-battle]').forEach(form=>{
      const winnerSelect=form.elements.winner_state_id;
      const updateRetreats=()=>form.querySelectorAll('[data-retreat-state]').forEach(select=>{const isWinner=Number(select.dataset.retreatState)===Number(winnerSelect.value);select.disabled=isWinner;select.required=!isWinner;if(isWinner)select.value='';});
      winnerSelect.onchange=updateRetreats;updateRetreats();
      form.onsubmit=event=>{
      event.preventDefault();
      const body=new FormData(form),participants=(data.battles||[]).find(b=>Number(b.id)===Number(form.dataset.resolveBattle))?.participants||[];
      const losses=[];
      participants.forEach(p=>(p.units||[]).forEach(u=>losses.push({formation_id:Number(p.formation_id),unit_id:Number(u.unit_id),losses:Math.max(0,Math.floor(Number(body.get(`loss_${p.formation_id}_${u.unit_id}`))||0))})));
      const retreats=participants.filter(p=>p.kind!=='garrison'&&Number(p.state_id)!==Number(form.elements.winner_state_id.value)).map(p=>({formation_id:Number(p.formation_id),province_id:Number(body.get(`retreat_${p.formation_id}`))}));
      const payload={winner_state_id:Number(form.elements.winner_state_id.value),losses,retreats};
      if(form.dataset.navalStates){payload.naval_states=JSON.parse(form.dataset.navalStates);payload.naval_captures=JSON.parse(form.dataset.navalCaptures||'[]');payload.naval_report=JSON.parse(form.dataset.navalReport||'null');}
      void (async()=>{form.querySelector('button[type="submit"]').disabled=true;try{await militaryBattleApi(Number(form.dataset.resolveBattle),payload);notify?.('Исход сражения сохранён');window.dispatchEvent(new Event('map:refresh'));await refresh();}catch(error){notify?.(error.message);form.querySelector('button[type="submit"]').disabled=false;}})();
      };
    });
    if(activeMilitaryTab==='Гарнизоны')renderGarrisonPanel(host.querySelector('[data-garrison-panel]'),garrisons,{stateId,notify,refresh,onMapChange});
    if(activeMilitaryTab==='Ополчение')renderMilitiaPanel(host.querySelector('[data-militia-panel]'),militia,data,{stateId,notify,onMapChange});
    if(activeMilitaryTab==='Обзор'){
      host.querySelectorAll('[data-hire-unit]').forEach(form=>{
        const unit=data.catalog.find(item=>Number(item.id)===Number(form.dataset.hireUnit));if(!unit)return;
        const provinceSelect=form.elements.province_id,formationSelect=form.closest('tr').querySelector('select[aria-label="Формирование"]'),quantity=form.closest('tr').querySelector('input[name="quantity"]'),submit=form.closest('tr').querySelector('[data-hire-submit]'),estimate=form.closest('tr').querySelector('[data-hire-estimate]');
        formationSelect.setAttribute('form',form.id||`hire-form-${unit.id}`);form.id=formationSelect.getAttribute('form');quantity.setAttribute('form',form.id);submit.setAttribute('form',form.id);
        let estimateTimer,estimateRevision=0;
        const updateEstimate=()=>{clearTimeout(estimateTimer);const revision=++estimateRevision;estimate.textContent='Проверяю стоимость…';estimateTimer=setTimeout(async()=>{try{const result=await militaryApi('preview_hire',stateId,{unit_id:Number(unit.id),quantity:Number(quantity.value),province_id:Number(provinceSelect.value),formation_id:formationSelect.value?Number(formationSelect.value):null});if(revision===estimateRevision&&form.isConnected)estimate.textContent=`${fmt(result.cost)} G · ${fmt(result.recruits)} рекр.`;}catch(error){if(revision===estimateRevision&&form.isConnected)estimate.textContent=error.message;}},250);};
        formationSelect.onchange=()=>{const id=Number(formationSelect.value);if(id){const formation=regular.find(item=>Number(item.id)===id);if(formation)provinceSelect.value=String(formation.province_id);provinceSelect.disabled=true;}else provinceSelect.disabled=false;updateEstimate();};
        quantity.oninput=updateEstimate;quantity.onfocus=updateEstimate;provinceSelect.onchange=updateEstimate;
        form.addEventListener('submit',event=>{event.preventDefault();const amount=Number(quantity.value);if(!Number.isInteger(amount)||amount<1)return;void run(host,'hire',stateId,{unit_id:Number(unit.id),quantity:amount,province_id:Number(provinceSelect.value),formation_id:formationSelect.value?Number(formationSelect.value):null,name:unit.domain==='naval'?'Новая флотилия':'Новая армия'},notify,refresh);});
      });
    }
    if(activeMilitaryTab==='Армии и флот'){
      const createForm=host.querySelector('.military-create-formation'),domainSelect=createForm?.elements.domain,locationSelect=createForm?.elements.province_id;
      const updateCreateLocations=()=>{if(!locationSelect)return;const domain=domainSelect.value;[...locationSelect.options].forEach(option=>{option.hidden=option.dataset.domain!==domain;option.disabled=option.hidden||!option.value;});const first=[...locationSelect.options].find(option=>option.dataset.domain===domain&&option.value);locationSelect.value=first?.value||'';createForm.querySelector('[type="submit"]').disabled=!first;};
      domainSelect?.addEventListener('change',updateCreateLocations);updateCreateLocations();
      createForm?.addEventListener('submit',event=>{event.preventDefault();const body=Object.fromEntries(new FormData(createForm));void run(host,'create_formation',stateId,{domain:body.domain,name:body.name,province_id:Number(body.province_id)},notify,refresh);});
      host.querySelectorAll('[data-rename-formation]').forEach(form=>form.addEventListener('submit',event=>{event.preventDefault();void run(host,'rename_formation',stateId,{formation_id:Number(form.dataset.renameFormation),name:form.elements.name.value},notify,refresh);}));
      host.querySelectorAll('[data-open-formation]').forEach(button=>button.onclick=()=>host.querySelector(`[data-formation-dialog="${button.dataset.openFormation}"]`)?.showModal());
      host.querySelectorAll('[data-close-formation]').forEach(button=>button.onclick=()=>button.closest('dialog')?.close());
      host.querySelectorAll('.military-formation-dialog').forEach(dialog=>dialog.addEventListener('click',event=>{if(event.target===dialog)dialog.close();}));
      host.querySelectorAll('[data-composition-unit]').forEach(select=>select.addEventListener('change',()=>{
        const option=select.selectedOptions[0],quantity=select.form?.elements.quantity;
        if(!quantity)return;
        const selectedLimit=Number(option?.dataset.quantity)||0;
        const isSplit=Boolean(select.form.matches('[data-composition-split]'));
        const total=Number(select.form.dataset.totalUnits)||selectedLimit;
        quantity.max=String(isSplit?Math.min(selectedLimit,Math.max(0,total-1)):selectedLimit);
        if(Number(quantity.value)>Number(quantity.max))quantity.value=quantity.max;
        if(Number(quantity.value)<1&&Number(quantity.max)>=1)quantity.value='1';
      }));
      host.querySelectorAll('[data-composition-split]').forEach(form=>form.addEventListener('submit',event=>{
        event.preventDefault();const body=Object.fromEntries(new FormData(form));
        void run(host,'split_formation',stateId,{formation_id:Number(form.dataset.compositionSplit),name:body.name,units:[{unit_id:Number(body.unit_id),quantity:Number(body.quantity)}]},notify,refresh);
      }));
      host.querySelectorAll('[data-composition-transfer]').forEach(form=>form.addEventListener('submit',event=>{
        event.preventDefault();const body=Object.fromEntries(new FormData(form));
        void run(host,'transfer_units',stateId,{source_formation_id:Number(form.dataset.compositionTransfer),target_formation_id:Number(body.target_formation_id),unit_id:Number(body.unit_id),quantity:Number(body.quantity)},notify,refresh);
      }));
      host.querySelectorAll('[data-composition-merge]').forEach(form=>form.addEventListener('submit',event=>{
        event.preventDefault();const body=Object.fromEntries(new FormData(form));
        void run(host,'merge_formations',stateId,{source_formation_id:Number(form.dataset.compositionMerge),target_formation_id:Number(body.target_formation_id)},notify,refresh);
      }));
      host.querySelectorAll('[data-assign-leader]').forEach(select=>select.onchange=()=>void run(host,'assign_leader',stateId,{formation_id:Number(select.dataset.assignLeader),leader_id:select.value||null},notify,refresh));
      host.querySelectorAll('[data-transport-action]').forEach(form=>form.addEventListener('submit',event=>{
        event.preventDefault();const action=form.dataset.transportAction,body=new FormData(form),armyId=Number(form.dataset.army||body.get('army_id')),fleetId=Number(form.dataset.fleet||body.get('fleet_id'));
        void (async()=>{const button=form.querySelector('button[type="submit"]');button.disabled=true;try{await militaryTransportApi(action,armyId,fleetId,action==='disembark'?Number(body.get('target_province')):null);notify?.(action==='embark'?'Армия погружена на флот':'Армия высажена на берег');window.dispatchEvent(new Event('map:refresh'));await refresh();}catch(error){notify?.(error.message);button.disabled=false;}})();
      }));
    }
    if(activeMilitaryTab==='Полководцы'){
      const section=host.querySelector('.state-menu > .stack');
      data.leaders.filter(l=>Number(l.rolls?.free_points)>0).forEach(leader=>{
        const form=document.createElement('form');form.className='application-panel stack';form.dataset.allocateLeader=leader.id;
        form.innerHTML=`<h4>Свободные очки: ${escape(leader.name)}</h4><p>Распределить: ${Number(leader.rolls.free_points)}</p>${Object.entries(leader.skills||{}).map(([name,value])=>`<label class="field"><span>${escape(name)} · сейчас ${value}</span><input type="number" name="${escape(name)}" min="0" max="${Math.min(6-Number(value),Number(leader.rolls.free_points))}" value="0" required></label>`).join('')}<button type="submit">Сохранить навыки</button>`;
        section.append(form);
      });
      host.querySelectorAll('[data-allocate-leader]').forEach(form=>form.onsubmit=event=>{event.preventDefault();const allocation=Object.fromEntries([...new FormData(form)].map(([name,value])=>[name,Number(value)]));void run(host,'allocate_leader',stateId,{leader_id:Number(form.dataset.allocateLeader),allocation},notify,refresh);});
    }
    host.querySelectorAll('[data-military-tab]').forEach(button=>button.onclick=()=>{activeMilitaryTab=button.dataset.militaryTab;void refresh();});
    host.querySelectorAll('[data-hire-mercenary]').forEach(button=>button.onclick=()=>void run(host,'hire_mercenary',stateId,{group_id:Number(button.dataset.hireMercenary)},notify,refresh));
    const mercForm=host.querySelector('[data-mercenary-create]');
    if(mercForm){
      const add=document.createElement('button');add.type='button';add.textContent='+ Ещё тип войск';
      mercForm.querySelector('[type="submit"]').before(add);
      add.onclick=()=>{const row=document.createElement('div');row.className='inline-actions';row.dataset.mercUnitRow='';row.innerHTML=`<select aria-label="Тип войск">${data.catalog.filter(u=>u.domain==='land').map(u=>`<option value="${u.id}">${escape(u.name)}</option>`).join('')}</select><input aria-label="Количество" type="number" min="1" value="100"><button type="button" aria-label="Удалить строку">×</button>`;row.querySelector('button').onclick=()=>row.remove();add.before(row);};
      mercForm.addEventListener('submit',event=>{event.preventDefault();const body=Object.fromEntries(new FormData(mercForm));const rows=[{unit_id:Number(body.unit_id),quantity:Number(body.quantity)},...[...mercForm.querySelectorAll('[data-merc-unit-row]')].map(row=>({unit_id:Number(row.querySelector('select').value),quantity:Number(row.querySelector('input').value)}))];const totals=new Map();rows.forEach(row=>totals.set(row.unit_id,(totals.get(row.unit_id)||0)+row.quantity));const composition=[...totals].map(([unit_id,quantity])=>({unit_id,quantity}));void run(host,'admin_mercenary',stateId,{name:body.name,leader_name:body.leader_name,leader_skills:{description:body.leader_skills},city_province_id:Number(body.city_province_id),composition,price:Number(body.price)},notify,refresh);});
    }
    host.querySelector('[data-hire-leader]')?.addEventListener('submit',event=>{event.preventDefault();void run(host,'hire_leader',stateId,Object.fromEntries(new FormData(event.currentTarget)),notify,refresh);});
    host.querySelector('[data-admin-unit]')?.addEventListener('submit',event=>{event.preventDefault();void run(host,'admin_unit',stateId,Object.fromEntries(new FormData(event.currentTarget)),notify,refresh);});
    if(openFormationId){
      const dialog=host.querySelector(`[data-formation-dialog="${openFormationId}"]`);
      if(dialog)dialog.showModal();
    }
  }catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

function renderMilitiaPanel(host,militia,military,{stateId,notify,onMapChange}){
  const call=militia.call,preview=militia.preview;
  const active=call?.status==='active';
  const plan=active?call.plan:preview;
  const title={pending:'Заявка на рассмотрении судьи',approved:'Созыв разрешён, ополчение появится в следующий ход',active:'Ополчение созвано',rejected:'Последняя заявка отклонена',disbanded:'Ополчение распущено'}[call?.status]||'Ополчение не созвано';
  const cooldown=call?.status==='disbanded'&&Number(militia.turn)<=Number(call.disbanded_turn);
  const canRequest=!['pending','approved','active'].includes(call?.status)&&!cooldown&&Number(preview.total)>0;
  const unitEntries=Object.entries(plan.units||{}).filter(([,quantity])=>Number(quantity)>0);
  const navalEntries=(plan.naval_fleets||[]).flatMap(fleet=>Number(fleet.cogs)>0?[['Когг',Number(fleet.cogs)]]:[]);
  const navalCrew=Number(plan.naval_crew_recruits||0);
  const activeFunding=military.upkeep_breakdown?.militia_by_estate;
  const fundingSource=active?(activeFunding||{}):(plan.funding_by_estate||{});
  const upkeep=Number(active?military.upkeep_breakdown?.militia:plan.upkeep||0);
  const contributions=Object.entries(plan.contributions||{}).filter(([,quantity])=>Number(quantity)>0);
  const funding=Object.entries(fundingSource).filter(([,amount])=>Number(amount)>0)
    .map(([estate,amount])=>`${escape(estate)}: ${fmt(amount)} G`).join(' · ')||`Корона: ${fmt(upkeep)} G`;
  host.innerHTML=`<section class="application-panel stack"><div><h4>Сословное ополчение</h4><p class="hint">${escape(title)}${cooldown?' · Новый созыв доступен после завершения текущего хода.':''}</p></div><div class="state-dashboard-card"><p>Доктрина <strong>${escape(plan.doctrine||'—')}</strong></p><p>Мобилизационный пул <strong>${fmt(plan.total)} человек</strong></p>${navalCrew>0?`<p>Экипаж коггов <strong>${fmt(navalCrew)} рекрутов</strong></p>`:""}<p>Коэффициент мобилизации <strong>× ${escape(plan.coefficient)}</strong></p><p>Расчётное содержание <strong>${fmt(upkeep)} G / ход</strong></p><p class="hint">${escape(funding)}</p></div><p class="hint">${active?'Показаны данные созванного ополчения.':'Прогноз обновится при начале следующего хода с учётом населения, контроля и оккупации.'} Лояльность учитывается на уровне государства.</p><div class="inline-actions">${active?'<button type="button" data-militia-disband>Распустить ополчение</button>':`<button type="button" class="primary" data-militia-request ${canRequest?'':'disabled'}>Созвать ополчение</button>`}</div>${!active&&!canRequest&&!cooldown&&Number(preview.total)<1?'<p class="hint">Нет доступного мобилизационного пула.</p>':''}<p class="form-message" data-militia-message aria-live="polite"></p></section><section class="application-panel"><h4>Состав по юнитам</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Юнит</th><th>Количество</th></tr></thead><tbody>${[...unitEntries,...navalEntries].map(([name,quantity])=>`<tr><td>${escape(name)}</td><td>${fmt(quantity)}</td></tr>`).join('')||'<tr><td colspan="2">Нет доступных юнитов.</td></tr>'}</tbody></table></div></section><section class="application-panel"><h4>Провинции и сословия</h4><p class="hint">${contributions.map(([name,quantity])=>`${escape(name)}: ${fmt(quantity)}`).join(' · ')||'Вкладов нет.'}</p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Провинция</th><th>Людей</th></tr></thead><tbody>${(plan.provinces||[]).map(p=>`<tr><td>${escape(p.name)}</td><td>${fmt(p.total)}</td></tr>`).join('')||'<tr><td colspan="2">Нет подконтрольных провинций с доступным населением.</td></tr>'}</tbody></table></div></section>`;
  const submit=async(action,confirmation)=>{
    if(!window.confirm(confirmation))return;
    const button=host.querySelector(action==='request'?'[data-militia-request]':'[data-militia-disband]');
    button.disabled=true;
    try{
      const result=await militiaApi(action,stateId);
      notify?.(action==='request'?'Заявка отправлена судье':`Ополчение распущено. Вернулось ${fmt(result.survivors_returned)} человек.`);
      window.dispatchEvent(new Event('state:resources-changed'));onMapChange?.();
      await renderMilitaryPanel(host.closest('[data-state-military]'),{stateId,notify,onMapChange});
    }catch(error){host.querySelector('[data-militia-message]').textContent=error.message;button.disabled=false;}
  };
  host.querySelector('[data-militia-request]')?.addEventListener('click',()=>void submit('request',`Отправить судье заявку на созыв ${fmt(preview.total)} ополченцев? Войско появится на следующий ход после разрешения.`));
  host.querySelector('[data-militia-disband]')?.addEventListener('click',()=>void submit('disband','Распустить всё сословное ополчение? Выжившие вернутся в население провинций, потери останутся безвозвратными.'));
}

export async function renderMilitaryDiplomacy(host,{stateId,notify}={}){
  if(!host)return;
  host.innerHTML='<p class="hint">Загружаю отношения…</p>';
  try{
    const data=await militaryApi('snapshot',stateId);if(!host.isConnected)return;
    const refresh=()=>renderMilitaryDiplomacy(host,{stateId,notify});
    const own=data.states.find(s=>s.id===data.state_id)?.name||'Государство';
    host.innerHTML=`<section class="application-panel"><h4>Отношения государства «${escape(own)}»</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Государство</th><th>Отношения</th></tr></thead><tbody>${data.states.filter(s=>s.id!==data.state_id).map(s=>`<tr><td>${escape(s.name)}</td><td>${relations[s.relation]||escape(s.relation)}</td></tr>`).join('')}</tbody></table></div></section><section class="application-panel"><h4>Военные договоры</h4>${data.diplomacy.map(d=>`<article class="marriage-candidate"><strong>${kinds[d.kind]} · ${escape(data.states.find(s=>s.id===d.from_state_id)?.name)} → ${escape(data.states.find(s=>s.id===d.to_state_id)?.name)}</strong><p>${status[d.status]||escape(d.status)}${d.justified===true?' · оправданная война':d.justified===false?' · неоправданная война':''}</p>${d.casus_belli?`<p>Повод: ${escape(d.casus_belli)}</p>`:''}${d.terms?`<p>Условия: ${escape(d.terms)}</p>`:''}${d.status==='pending'&&d.to_state_id===data.state_id?`<div class="inline-actions"><button data-military-decision="accept" data-request-id="${d.id}">Принять</button><button data-military-decision="reject" data-request-id="${d.id}">Отклонить</button></div>`:''}${d.kind==='passage'&&d.status==='accepted'?`<button data-military-decision="end" data-request-id="${d.id}">Расторгнуть</button>`:''}</article>`).join('')||'<p class="hint">Договоров пока нет.</p>'}</section>`;
    host.querySelectorAll('[data-military-decision]').forEach(button=>button.onclick=()=>void run(host,'decide',stateId,{id:Number(button.dataset.requestId),decision:button.dataset.militaryDecision},notify,refresh));
  }catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

export async function renderMilitaryContract(host,kind,{stateId,notify}={}){
  if(!host)return;
  const data=await militaryApi('snapshot',stateId);
  if(!host.isConnected)return;
  const targets=data.states.filter(s=>s.id!==data.state_id&&(kind!=='peace'||s.relation.includes('war')));
  host.innerHTML=`<form class="stack"><label class="field"><span>Государство</span><select name="to_state_id">${targets.map(s=>`<option value="${s.id}">${escape(s.name)}</option>`).join('')}</select></label>${kind==='war'?`<label class="field"><span>Casus Belli</span><select name="casus_belli">${casusBelli.map(x=>`<option>${escape(x)}</option>`).join('')}</select></label>`:''}${kind==='peace'||kind==='passage'?`<label class="field"><span>${kind==='peace'?'Условия мира':'Условия прохода'}</span><textarea name="terms" ${kind==='peace'?'required':''} rows="4"></textarea></label>`:''}<p class="hint">Стоимость действия: 0 ОП. ${kind==='war'?'Война начнётся после решения администратора.':''}</p><button class="primary" type="submit" ${targets.length?'':'disabled'}>Отправить</button></form>`;
  host.querySelector('form').onsubmit=event=>{event.preventDefault();const body=Object.fromEntries(new FormData(event.currentTarget));void run(host,'propose',stateId,{kind,...body,to_state_id:Number(body.to_state_id)},notify,()=>renderMilitaryContract(host,kind,{stateId,notify}));};
}

export async function renderMilitaryAdminQueue(host,{notify}={}){
  if(!host)return;
  try{
    const [data,militia]=await Promise.all([militaryApi('admin_queue'),militiaApi('admin_queue')]);
    if(!host.isConnected)return;
    host.innerHTML=`<section class="application-panel"><h3>Военные решения судьи</h3>${militia.requests.map(d=>`<article class="marriage-candidate"><strong>Созыв ополчения · ${escape(d.state_name)}</strong><p>${fmt(d.plan?.total)} человек · ${escape(d.doctrine)} · год запроса: ход ${fmt(d.requested_turn)}</p><div class="inline-actions"><button type="button" data-admin-militia="approve" data-state="${d.state_id}">Разрешить</button><button type="button" data-admin-militia="reject" data-state="${d.state_id}">Запретить</button></div></article>`).join('')}${data.requests.map(d=>`<article class="marriage-candidate"><strong>${kinds[d.kind]} · ${d.from_state_id} → ${d.to_state_id}</strong><p>${escape(d.casus_belli||d.terms)}</p><div class="inline-actions">${d.kind==='war'?`<button data-admin-military="accept" data-justified="true" data-state="${d.from_state_id}" data-id="${d.id}">Оправданная война</button><button data-admin-military="accept" data-justified="false" data-state="${d.from_state_id}" data-id="${d.id}">Неоправданная война</button>`:`<button data-admin-military="accept" data-state="${d.from_state_id}" data-id="${d.id}">Утвердить мир</button>`}<button data-admin-military="reject" data-state="${d.from_state_id}" data-id="${d.id}">Отклонить</button></div></article>`).join('')||(!militia.requests.length?'<p class="hint">Нет решений на рассмотрении.</p>':'')}</section>`;
    host.querySelectorAll('[data-admin-militia]').forEach(button=>button.onclick=async()=>{
      const decision=button.dataset.adminMilitia,state=Number(button.dataset.state);
      if(!window.confirm(`${decision==='approve'?'Разрешить':'Запретить'} созыв ополчения государства № ${state}?`))return;
      button.disabled=true;
      try{await militiaApi('decide',state,{decision});notify?.('Решение по ополчению сохранено');await renderMilitaryAdminQueue(host,{notify});}
      catch(error){notify?.(error.message);button.disabled=false;}
    });
    host.querySelectorAll('[data-admin-military]').forEach(button=>button.onclick=()=>void run(host,'decide',Number(button.dataset.state),{id:Number(button.dataset.id),decision:button.dataset.adminMilitary,justified:button.dataset.justified==='true'},notify,()=>renderMilitaryAdminQueue(host,{notify})));
  }catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}
