import {militaryApi,militiaApi} from './supabase-api.js?v=militia-20261026';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=value=>Math.floor(Number(value)||0).toLocaleString('ru-RU');
const domains={land:'Сухопутные',naval:'Морские',siege:'Осадные'};
const relations={own:'Своё государство',peace:'Мир',justified_war:'Оправданная война',unjustified_war:'Неоправданная война'};
const status={pending:'Ожидает ответа',awaiting_admin:'На рассмотрении судьи',accepted:'Действует',rejected:'Отклонено',ended:'Расторгнуто'};
const kinds={war:'Объявление войны',peace:'Заключение мира',passage:'Право прохода'};
export const casusBelli=['Завоевание','Священная война','Реконкиста','Торговый спор','Оскорбление чести','Династическая уния','Поддержка повстанцев','Ликвидация угрозы','Поддержка союзника','Война без Casus Belli, Король так захотел!'];
let activeMilitaryTab='Обзор';

async function run(host,action,stateId,payload,notify,refresh){
  const buttons=[...host.querySelectorAll('button')];buttons.forEach(button=>button.disabled=true);
  try{const result=await militaryApi(action,stateId,payload);window.dispatchEvent(new Event('state:resources-changed'));notify?.('Действие выполнено');await refresh();return result;}
  catch(error){notify?.(error.message);buttons.forEach(button=>button.disabled=false);return null;}
}

export async function renderMilitaryPanel(host,{stateId,notify,onMapChange}={}){
  if(!host)return;
  host.innerHTML='<p class="hint">Загружаю военное дело…</p>';
  try{
    const [data,militia]=await Promise.all([militaryApi('snapshot',stateId),militiaApi('snapshot',stateId)]);
    if(!host.isConnected)return;
    const refresh=()=>renderMilitaryPanel(host,{stateId,notify,onMapChange});
    const tabs=['Обзор','Армии и флот','Ополчение','Наёмники','Полководцы','Каталог'];
    if(activeMilitaryTab==='Найм')activeMilitaryTab='Обзор';
    if(activeMilitaryTab==='Командиры')activeMilitaryTab='Полководцы';
    if(!tabs.includes(activeMilitaryTab))activeMilitaryTab='Обзор';
    const provinceName=id=>data.provinces.find(p=>Number(p.id)===Number(id))?.name||`№ ${id}`;
    const ownedCities=data.provinces.filter(p=>p.kind==='land'&&p.owned&&(p.city||p.capital));
    const ports=data.provinces.filter(p=>p.kind==='sea'&&p.port);
    const placesFor=domain=>domain==='naval'?ports:ownedCities;
    const upkeepOf=(f,item)=>Math.floor(Number(item.upkeep||0)*Math.max(0,Number(item.quantity)-(item.name==='Копейщик'?Math.min(Number(item.quantity),Number(f.free_upkeep_quantity||0)):0)));
    const regular=data.formations.filter(f=>f.kind==='regular');
    const leaders=data.leaders,activeLeaders=leaders.filter(l=>l.status==='active');
    const generals=leaders.filter(l=>l.domain==='land').length,admirals=leaders.filter(l=>l.domain==='naval').length;
    const armyUpkeep=data.formations.filter(f=>f.kind==='regular'&&f.domain==='land').reduce((sum,f)=>sum+f.units.reduce((n,u)=>n+upkeepOf(f,u),0),0);
    const fleetUpkeep=data.formations.filter(f=>f.kind==='regular'&&f.domain==='naval').reduce((sum,f)=>sum+f.units.reduce((n,u)=>n+upkeepOf(f,u),0),0);
    const mercenaryUpkeep=data.formations.filter(f=>f.kind==='mercenary').reduce((sum,f)=>sum+Number(data.mercenaries.find(g=>Number(g.id)===Number(f.mercenary_group_id))?.price||0),0);
    const militiaFormation=data.formations.find(f=>f.kind==='militia'&&f.active);
    const militiaUpkeep=militiaFormation?militiaFormation.units.reduce((sum,u)=>sum+Number(u.quantity||0)*Number(u.upkeep||0),0):0;
    const upkeep=armyUpkeep+fleetUpkeep+mercenaryUpkeep+militiaUpkeep;
    const catalogTable=domain=>`<section class="application-panel"><h4>${domains[domain]}</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Юнит</th><th>Категория</th><th>Здоровье</th><th>Урон</th><th>Броня</th><th>Инициатива</th><th>Рекруты</th><th>Цена</th><th>Содержание</th><th>Условие</th></tr></thead><tbody>${data.catalog.filter(u=>u.domain===domain).map(u=>`<tr><td>${escape(u.name)}</td><td>${escape(u.category)}</td><td>${u.health}</td><td>${u.damage}${u.charge_damage?` (${u.charge_damage})`:''}</td><td>${u.armor}</td><td>${u.initiative}</td><td>${u.recruit_cost}</td><td>${fmt(u.hire_cost)}</td><td>${fmt(u.upkeep)}</td><td>${u.prerequisite==='saltpeter'?'Избыток селитры':'—'}</td></tr>`).join('')}</tbody></table></div></section>`;
    const locationOptions=domain=>placesFor(domain).map(p=>`<option value="${p.id}">${escape(p.name)}${p.port?' · порт':''}</option>`).join('');
    const hiringRows=data.catalog.filter(u=>u.hireable).map(unit=>{
      const domain=unit.domain==='naval'?'naval':'land',placeList=placesFor(domain),matching=regular.filter(f=>f.domain===domain);
      const formationOptions=matching.map(f=>`<option value="${f.id}" data-province="${f.province_id}">${escape(f.name)}</option>`).join('');
      return `<tr><td><strong>${escape(unit.name)}</strong></td><td>${escape(unit.category)}</td><td>${fmt(unit.hire_cost)} G</td><td>${fmt(unit.upkeep)} G</td><td>${fmt(unit.recruit_cost)}</td><td><form class="military-hire-row" data-hire-unit="${unit.id}"><select name="province_id" aria-label="Место найма" required ${placeList.length?'':'disabled'}>${locationOptions(domain)}</select></form></td><td><select form="" name="formation_id" aria-label="Формирование"><option value="">Новое</option>${formationOptions}</select></td><td><input form="" name="quantity" type="number" min="1" max="100000" step="1" value="1" aria-label="Количество" ${placeList.length?'':'disabled'}></td><td><span data-hire-estimate>${fmt(unit.hire_cost)} G · ${fmt(unit.recruit_cost)} рекр.</span></td><td><button type="submit" form="" class="primary" data-hire-submit="${unit.id}" ${placeList.length?'':'disabled'}>Нанять</button></td></tr>`;
    }).join('');
    const hirePanel=`<section class="application-panel"><h4>Найм регулярной армии</h4><p class="hint">Выберите провинцию, при желании — существующее формирование, укажите количество и нажмите «Нанять».</p><div class="table-scroll"><table class="state-data-table military-hiring-table"><thead><tr><th>Название</th><th>Категория</th><th>Цена за часть</th><th>Содержание / ход</th><th>Рекруты / часть</th><th>Место</th><th>Формирование</th><th>Количество</th><th>Итого</th><th></th></tr></thead><tbody>${hiringRows||'<tr><td colspan="10">Нет доступных для найма частей.</td></tr>'}</tbody></table></div></section>`;
    const expenseRows=[['Армия',fmt(armyUpkeep)],['Флот',fmt(fleetUpkeep)],['Ополчение',fmt(militiaUpkeep)],['Наёмники',fmt(mercenaryUpkeep)],['Крепости','—'],['Гарнизоны','—']].map(([label,value])=>`<div><span>${label}</span><strong>${value}${value==='—'?'':' G'}</strong></div>`).join('');
    const overview=`<div class="military-overview"><aside class="military-overview-side"><section class="state-dashboard-card"><h4>Традиции</h4><p>Военные <strong>${fmt(data.traditions?.land)}%</strong></p><p>Морские <strong>${fmt(data.traditions?.naval)}%</strong></p></section><section class="state-dashboard-card"><h4>Рекруты</h4><p>Доступно <strong>${fmt(data.recruits)}</strong></p><p>Лимит <strong>${fmt(data.recruitment?.recruit_limit)}</strong></p><p>Прирост / ход <strong>${fmt(data.recruitment?.recruit_growth)}</strong></p></section><section class="state-dashboard-card"><h4>Полководцы</h4><p>Доступно <strong>${fmt(Math.max(0,Number(data.leader_limit||0)-leaders.length))}</strong></p><p>Лимит <strong>${fmt(data.leader_limit)}</strong></p><p>Генералы <strong>${generals}</strong></p><p>Адмиралы <strong>${admirals}</strong></p></section><section class="state-dashboard-card"><h4>Расходы / ход</h4>${expenseRows}<p>Всего <strong>${fmt(upkeep)} G</strong></p></section></aside><div class="military-overview-main">${hirePanel}</div></div>`;
    const formationRows=data.formations.map((f,formationIndex)=>{
      const units=f.units.length?f.units:[null],leaderOptions=activeLeaders.filter(l=>l.domain===f.domain).map(l=>`<option value="${l.id}" ${Number(f.leader_id)===Number(l.id)?'selected':''}>${escape(l.name)}</option>`).join('');
      const heading=`<tr class="military-formation-heading"><th colspan="7"><form class="military-rename-formation" data-rename-formation="${f.id}"><input name="name" maxlength="100" minlength="2" required value="${escape(f.name)}" aria-label="Название формирования"><button type="submit">Сохранить</button></form></th></tr>`;
      const separator=formationIndex?'<tr class="military-formation-gap"><td colspan="7"></td></tr>':'';
      return separator+heading+units.map((unit,index)=>`<tr>${index===0?`<td rowspan="${units.length}">${escape(provinceName(f.province_id))}</td><td rowspan="${units.length}">${f.kind==='regular'?`<select data-assign-leader="${f.id}"><option value="">Без полководца</option>${leaderOptions}</select>`:'—'}</td>`:''}<td>${unit?escape(unit.name):'—'}</td><td>${unit?escape(domains[data.catalog.find(c=>Number(c.id)===Number(unit.unit_id))?.domain]||'Часть'):'—'}</td><td>${unit?fmt(unit.quantity):'—'}</td><td>${unit?fmt(unit.upkeep):'—'}${unit?' G':''}</td><td>${unit?fmt(f.kind==='mercenary'&&index===0?Number(data.mercenaries.find(g=>Number(g.id)===Number(f.mercenary_group_id))?.price||0):upkeepOf(f,unit)):'—'}${unit?' G':''}</td></tr>`).join('');
    }).join('');
    const formationTable=`<section class="application-panel"><h4>Создать армию или флотилию</h4><form class="inline-actions military-create-formation"><select name="domain" aria-label="Тип формирования"><option value="land">Армия</option><option value="naval">Флотилия</option></select><input name="name" minlength="2" maxlength="100" required placeholder="Название формирования"><select name="province_id" data-create-location required aria-label="Место базирования"><option value="" data-domain="land">${ownedCities.length?'Выберите город':'Нет своего города с маркером'}</option>${ownedCities.map(p=>`<option value="${p.id}" data-domain="land">${escape(p.name)}</option>`).join('')}<option value="" data-domain="naval">${ports.length?'Выберите порт':'Нет доступных портов'}</option>${ports.map(p=>`<option value="${p.id}" data-domain="naval">${escape(p.name)} · порт</option>`).join('')}</select><button type="submit" class="primary">Создать</button></form></section><section class="application-panel"><h4>Армии и флотилии</h4><div class="table-scroll"><table class="state-data-table military-formations-table"><thead><tr><th>Местоположение</th><th>Генерал / адмирал</th><th>Название юнита</th><th>Тип юнита</th><th>Количество</th><th>Содержание</th><th>Расходы</th></tr></thead><tbody>${formationRows||'<tr><td colspan="7">Формирований пока нет.</td></tr>'}</tbody></table></div></section>`;
    const content={
      'Обзор':overview,
      'Армии и флот':formationTable,
      'Ополчение':`<div data-militia-panel></div>`,
      'Наёмники':`<section class="application-panel"><h4>Доступные группы</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Город</th><th>Группа</th><th>Лидер и навыки</th><th>Состав</th><th>Цена за ход</th><th></th></tr></thead><tbody>${data.mercenaries.map(g=>`<tr><td>${escape(provinceName(g.city_province_id))}</td><td>${escape(g.name)}</td><td>${escape(g.leader_name)} · ${escape(JSON.stringify(g.leader_skills||{}))}</td><td>${(g.composition||[]).map(item=>`${escape(data.catalog.find(u=>Number(u.id)===Number(item.unit_id))?.name||item.unit_id)} × ${fmt(item.quantity)}`).join(', ')}</td><td>${fmt(g.price)} G</td><td>${g.hired_by?'Наняты':`<button data-hire-mercenary="${g.id}">Нанять</button>`}</td></tr>`).join('')}</tbody></table></div></section>${data.is_admin?`<section class="application-panel"><h4>Конструктор наёмников</h4><form data-mercenary-create class="stack"><label class="field"><span>Название группы</span><input name="name" required maxlength="100"></label><label class="field"><span>Лидер</span><input name="leader_name" required maxlength="100"></label><label class="field"><span>Навыки лидера</span><input name="leader_skills" placeholder="Натиск 2, Огонь 1"></label><label class="field"><span>Город базирования</span><select name="city_province_id">${data.provinces.filter(p=>p.city||p.capital).map(p=>`<option value="${p.id}">${escape(p.name)}</option>`).join('')}</select></label><label class="field"><span>Тип войск</span><select name="unit_id">${data.catalog.filter(u=>u.domain==='land').map(u=>`<option value="${u.id}">${escape(u.name)}</option>`).join('')}</select></label><label class="field"><span>Количество</span><input name="quantity" type="number" min="1" value="100" required></label><label class="field"><span>Цена</span><input name="price" type="number" min="0" value="1000" required></label><button type="submit">Создать группу</button></form></section>`:''}`,
      'Полководцы':`<section class="application-panel"><h4>Генералы и адмиралы</h4>${data.leaders.map(l=>`<p><strong>${escape(l.name)}</strong> · ${l.domain==='naval'?'Адмирал':'Генерал'} · ${escape(l.estate)} · Ур. ${l.level} · ${escape(Object.entries(l.skills||{}).map(([k,v])=>`${k} ${v}`).join(', '))}</p>`).join('')||'<p class="hint">Полководцев пока нет.</p>'}</section><section class="application-panel"><h4>Нанять полководца</h4><p class="hint">Базовая цена 2 500 G, 10 ОП и 5% соответствующей традиции. Сервер бросает кубики и записывает результат.</p><form data-hire-leader class="stack"><label class="field"><span>Имя</span><input name="name" required maxlength="100"></label><label class="field"><span>Роль</span><select name="domain"><option value="land">Генерал</option><option value="naval">Адмирал</option></select></label><label class="field"><span>Сословие</span><select name="estate">${['Знать','Духовенство','Горожане','Крестьяне'].map(x=>`<option>${x}</option>`).join('')}</select></label><button type="submit">Нанять полководца</button></form></section>`,
      'Каталог':Object.keys(domains).map(catalogTable).join('')+(data.is_admin?`<section class="application-panel"><h4>Добавить национальный тип войск</h4><p class="hint">Новая версия типа заменит старую в каталоге; уже нанятые юниты сохранят прежние характеристики.</p><form data-admin-unit class="stack"><label class="field"><span>Название</span><input name="name" required minlength="2" maxlength="80"></label><label class="field"><span>Род войск</span><select name="domain"><option value="land">Сухопутные</option><option value="naval">Морские</option><option value="siege">Осадные</option></select></label><label class="field"><span>Категория</span><input name="category" required></label>${[['health','Здоровье',10],['damage','Урон',1],['armor','Броня',1],['initiative','Инициатива',1],['recruit_cost','Рекруты',1],['hire_cost','Цена G',10],['upkeep','Содержание G',1],['power', 'Мощь',1],['capacity','Вместимость',0]].map(([name,label,value])=>`<label class="field"><span>${label}</span><input name="${name}" type="number" min="0" value="${value}" required></label>`).join('')}<label class="field"><span>Натиск</span><input name="charge_damage" type="number" min="0"></label><label class="field"><span>Условие</span><select name="prerequisite"><option value="none">Нет</option><option value="saltpeter">Избыток селитры</option></select></label><button type="submit">Сохранить юнит</button></form></section>`:''),
    };
    host.innerHTML=`<div class="state-menu stack"><nav class="state-subtabs" aria-label="Военное дело">${tabs.map(tab=>`<button type="button" data-military-tab="${escape(tab)}" class="${tab===activeMilitaryTab?'active':''}" ${tab===activeMilitaryTab?'aria-current="page"':''}>${escape(tab)}</button>`).join('')}</nav><div class="stack">${content[activeMilitaryTab]}</div></div>`;
    if(activeMilitaryTab==='Ополчение')renderMilitiaPanel(host.querySelector('[data-militia-panel]'),militia,data,{stateId,notify,onMapChange});
    if(activeMilitaryTab==='Обзор'){
      host.querySelectorAll('[data-hire-unit]').forEach(form=>{
        const unit=data.catalog.find(item=>Number(item.id)===Number(form.dataset.hireUnit));if(!unit)return;
        const provinceSelect=form.elements.province_id,formationSelect=form.closest('tr').querySelector('select[aria-label="Формирование"]'),quantity=form.closest('tr').querySelector('input[name="quantity"]'),submit=form.closest('tr').querySelector('[data-hire-submit]'),estimate=form.closest('tr').querySelector('[data-hire-estimate]');
        formationSelect.setAttribute('form',form.id||`hire-form-${unit.id}`);form.id=formationSelect.getAttribute('form');quantity.setAttribute('form',form.id);submit.setAttribute('form',form.id);
        const updateEstimate=()=>{const amount=Math.max(0,Math.floor(Number(quantity.value)||0));estimate.textContent=`${fmt(amount*Number(unit.hire_cost))} G · ${fmt(amount*Number(unit.recruit_cost))} рекр.`;};
        formationSelect.onchange=()=>{const opt=formationSelect.selectedOptions[0],id=Number(formationSelect.value);if(id){const formation=regular.find(item=>Number(item.id)===id);if(formation)provinceSelect.value=String(formation.province_id);provinceSelect.disabled=true;}else provinceSelect.disabled=false;};
        quantity.oninput=updateEstimate;updateEstimate();
        form.addEventListener('submit',event=>{event.preventDefault();const amount=Number(quantity.value);if(!Number.isInteger(amount)||amount<1)return;void run(host,'hire',stateId,{unit_id:Number(unit.id),quantity:amount,province_id:Number(provinceSelect.value),formation_id:formationSelect.value?Number(formationSelect.value):null,name:unit.domain==='naval'?'Новая флотилия':'Новая армия'},notify,refresh);});
      });
    }
    if(activeMilitaryTab==='Армии и флот'){
      const createForm=host.querySelector('.military-create-formation'),domainSelect=createForm?.elements.domain,locationSelect=createForm?.elements.province_id;
      const updateCreateLocations=()=>{if(!locationSelect)return;const domain=domainSelect.value;[...locationSelect.options].forEach(option=>{option.hidden=option.dataset.domain!==domain;option.disabled=option.hidden||!option.value;});const first=[...locationSelect.options].find(option=>option.dataset.domain===domain&&option.value);locationSelect.value=first?.value||'';createForm.querySelector('[type="submit"]').disabled=!first;};
      domainSelect?.addEventListener('change',updateCreateLocations);updateCreateLocations();
      createForm?.addEventListener('submit',event=>{event.preventDefault();const body=Object.fromEntries(new FormData(createForm));void run(host,'create_formation',stateId,{domain:body.domain,name:body.name,province_id:Number(body.province_id)},notify,refresh);});
      host.querySelectorAll('[data-rename-formation]').forEach(form=>form.addEventListener('submit',event=>{event.preventDefault();void run(host,'rename_formation',stateId,{formation_id:Number(form.dataset.renameFormation),name:form.elements.name.value},notify,refresh);}));
      host.querySelectorAll('[data-assign-leader]').forEach(select=>select.onchange=()=>void run(host,'assign_leader',stateId,{formation_id:Number(select.dataset.assignLeader),leader_id:select.value||null},notify,refresh));
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
  const upkeep=unitEntries.reduce((sum,[name,quantity])=>sum+Number(quantity)*Number(military.catalog.find(unit=>unit.name===name&&unit.state_id==null)?.upkeep||0),0);
  const contributions=Object.entries(plan.contributions||{}).filter(([,quantity])=>Number(quantity)>0);
  const burg=Number(plan.contributions?.Горожане||0),peas=Number(plan.contributions?.Крестьяне||0);
  const burgherCost=burg+peas?Math.floor(upkeep*.6*burg/(burg+peas)):0;
  const peasantCost=burg+peas?Math.floor(upkeep*.6*peas/(burg+peas)):0;
  const funding=plan.doctrine==='Фирд'?`Горожане: ${fmt(burgherCost)} G · Крестьяне: ${fmt(peasantCost)} G · Корона: ${fmt(upkeep-burgherCost-peasantCost)} G`:plan.doctrine==='Сословная армия'?`Знать: ${fmt(Math.floor(upkeep*.7))} G · Корона: ${fmt(upkeep-Math.floor(upkeep*.7))} G`:`Корона: ${fmt(upkeep)} G`;
  host.innerHTML=`<section class="application-panel stack"><div><h4>Сословное ополчение</h4><p class="hint">${escape(title)}${cooldown?' · Новый созыв доступен после завершения текущего хода.':''}</p></div><div class="state-dashboard-card"><p>Доктрина <strong>${escape(plan.doctrine||'—')}</strong></p><p>Мобилизационный пул <strong>${fmt(plan.total)} человек</strong></p><p>Коэффициент мобилизации <strong>× ${escape(plan.coefficient)}</strong></p><p>Расчётное содержание <strong>${fmt(upkeep)} G / ход</strong></p><p class="hint">${escape(funding)}</p></div><p class="hint">${active?'Показаны данные созванного ополчения.':'Прогноз обновится при начале следующего хода с учётом населения, контроля и оккупации.'} Лояльность учитывается на уровне государства.</p><div class="inline-actions">${active?'<button type="button" data-militia-disband>Распустить ополчение</button>':`<button type="button" class="primary" data-militia-request ${canRequest?'':'disabled'}>Созвать ополчение</button>`}</div>${!active&&!canRequest&&!cooldown&&Number(preview.total)<1?'<p class="hint">Нет доступного мобилизационного пула.</p>':''}<p class="form-message" data-militia-message aria-live="polite"></p></section><section class="application-panel"><h4>Состав по юнитам</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Юнит</th><th>Количество</th></tr></thead><tbody>${unitEntries.map(([name,quantity])=>`<tr><td>${escape(name)}</td><td>${fmt(quantity)}</td></tr>`).join('')||'<tr><td colspan="2">Нет доступных юнитов.</td></tr>'}</tbody></table></div></section><section class="application-panel"><h4>Провинции и сословия</h4><p class="hint">${contributions.map(([name,quantity])=>`${escape(name)}: ${fmt(quantity)}`).join(' · ')||'Вкладов нет.'}</p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Провинция</th><th>Людей</th></tr></thead><tbody>${(plan.provinces||[]).map(p=>`<tr><td>${escape(p.name)}</td><td>${fmt(p.total)}</td></tr>`).join('')||'<tr><td colspan="2">Нет подконтрольных провинций с доступным населением.</td></tr>'}</tbody></table></div></section>`;
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
