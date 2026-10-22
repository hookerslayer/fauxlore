import {supabaseApi,supabaseLogin,loadSupabaseInitialMap,hasAuthenticatedSession} from './supabase-api.js?v=20261022210000';
import {PRINCIPLES,governmentName,principleConflict} from './state-principles.js';
import {calculateProvinceEconomy,calculateProvinceValue,calculateStateProduction,calculateStatePolitics,getEconomyConfig,setEconomyConfig} from './economy.js?v=20261022250001';
const $=id=>document.getElementById(id);
export const LAYERS={states:'Государства',races:'Расы',religions:'Религии',resources:'Ресурсы',trade:'Торговые зоны',climate:'Климат',population:'Плотность населения',development:'Развитие'};
const MARKERS={capital:'Столица',city:'Город',fortress:'Крепость',port:'Порт'};
const INFO={roads:'Дороги',routes:'Торговые пути',provinces:'Названия провинций',states:'Названия государств',races:'Названия рас',religions:'Названия религий',resources:'Названия ресурсов',trade:'Названия торговых зон'};
const MENU=['Профиль','Стена','Статистика','Уведомления','Дипломатия','Власть и династия','Провинции','Города','Экономика','Производство','Торговля','Военное дело','Шпионаж','Правила и механики','Сообщество VK','Константы'];
const ADMIN_MENU=['Профиль','Стена','Государства','Уведомления','Правила и механики','Константы'];
const STATE_SECTIONS=['Статистика','Власть и династия','Дипломатия','Провинции','Экономика','Производство','Торговля'];
const PANELS={auth:['Авторизация','user-round','left'],menu:['Меню','menu','left'],legend:['Легенда','list','left'],control:['Управление','sliders-horizontal','right'],markers:['Маркеры','map-pin','right'],info:['Информация','info','right'],tools:['Инструменты','ruler','right'],admin:['Администрирование','shield','right']};
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const emit=(name,detail)=>window.dispatchEvent(new CustomEvent(name,{detail}));
let current=null,user=null,categories=[],allProvinces=[],provinceAdjacency={},mapMarkers=[],selectedProvince=null,pendingMarkerDraft=null,toolMode='',lastToolResult='',saveTimer,showStatus=()=>{},adminEditing=false,paintField='climate',paintValue='',paintActive=false,legendOpen=false,stateRows=[],applicationDraft=null,applicationPickMode=null,unreadNotificationCount=0,notificationFetchToken=0,activeMenuSection='Профиль',tradeRoutePick=null,pendingStateNavigation=null,activeContractType='dynastic_marriage',tradeAvailability={},tradeProposalDraft={fromStateId:null,toStateId:null,route:[],fromGoods:[{name:'',quantity:0}],toGoods:[{name:'',quantity:0}],fromGold:0,toGold:0};
const BELONGING_VALUES=['Корона','Знать','Духовенство','Горожане','Крестьяне','Отсутствует'];
const TRADE_STATUS_VALUES=['Отсутствует','Устье реки','Природный порт','Центр торговли I','Центр торговли II','Центр торговли III'];
const BULK_FIELDS=[['race','Раса'],['religion','Религия'],['state','Государство'],['occupation','Оккупация'],['population','Население'],['belonging','Принадлежность'],['trade_status','Торговый статус'],['resource','Ресурс'],['trade','Торговая зона'],['development','Развитие'],['control','Контроль, %'],['climate','Климат'],['terrain_type','Тип местности'],['capital','Маркер столицы'],['city','Маркер города']];
let bulkRules=[{condition_field:'climate',condition_value:'Холодный',target_field:'population',target_value:2000},{condition_field:'climate',condition_value:'Умеренный',target_field:'population',target_value:4000},{condition_field:'climate',condition_value:'Тропический',target_field:'population',target_value:5000}],bulkPreview=null,bulkBusy=false;
const panelPages={};let layoutFrame=0;
let adminTool='manual',colorLayer='resources',colorCategoryId=null;
const ADMIN_TOOLS={manual:'Ручное редактирование',bulk:'Массовое редактирование',markers:'Создать маркер',colors:'Цвета параметров',roads:'Прокладывание дорог',army:'Военные расходы'};
let economyDraft=null,economyLoading=false,economyDirty=false;
let armyBudget={state_id:null,units:[],treasury:0,debt:0},armyBudgetLoading=false,armyBudgetDirty=false,armyReport=null;
const ROAD_TYPES={trail:'Тропа',highway:'Тракт',imperial:'Имперская'};
let roadsList=[],roadInfo={active:false,busy:false,anchors:[],segments:[]},roadType='trail';
function roadMarkup(){
  const count=roadInfo.anchors.length;
  return group('Прокладывание дорог',`<label class="field"><span>Тип дороги</span><select id="road-type" ${roadInfo.active?'disabled':''}>${Object.entries(ROAD_TYPES).map(([key,name])=>`<option value="${key}" ${key===roadType?'selected':''}>${name}</option>`).join('')}</select></label><p class="hint">Клик по провинции — её центр. Клик по маркеру — сам маркер. Добавляйте соседние провинции последовательно. Пунктир — тропа, штрихи — тракт, сплошная линия — имперская дорога.</p>${roadInfo.active?`<div class="tool-result">Точек: ${count}${roadInfo.busy?' · Расчёт / сохранение…':''}</div><button id="road-undo" ${roadInfo.busy||!count?'disabled':''}>Убрать последнюю точку</button><button id="road-save" ${roadInfo.busy||count<2?'disabled':''}>Сохранить дорогу</button><button id="road-cancel" ${roadInfo.saving?'disabled':''}>Отмена</button>`:'<button id="road-start">Начать прокладывание</button>'}<p class="hint">Сохранённых дорог: ${roadsList.length}. Видимость переключается в панели «Информация → Дороги».</p>${roadsList.map(road=>`<div class="marker-admin-row"><span>№ ${road.id} · ${ROAD_TYPES[road.type]||escape(road.type)} · ${road.anchors.length} точек</span><button data-delete-road="${road.id}" ${roadInfo.busy?'disabled':''} aria-label="Удалить дорогу ${road.id}">×</button></div>`).join('')}`);
}
function armyBudgetMarkup(){
  const states=categories.filter(c=>c.layer==='states');
  const report=armyReport?.states?.length?`<div class="army-report"><strong>Отчёт за ${armyReport.year} год, ход ${armyReport.turn}</strong>${armyReport.states.map(s=>`<div class="army-report-row"><b>${escape(s.name)}</b><span>Содержание ${Number(s.army_upkeep||0).toLocaleString('ru-RU')} G · оплачено ${Number(s.army_upkeep_paid||0).toLocaleString('ru-RU')} G · долг +${Number(s.army_upkeep_arrears||0).toLocaleString('ru-RU')} G · погашено ${Number(s.debt_repaid||0).toLocaleString('ru-RU')} G · долг всего ${Number(s.treasury_debt||0).toLocaleString('ru-RU')} G${s.food_coverage_pct==null?'':` · продовольственная обеспеченность ${Number(s.food_coverage_pct).toLocaleString('ru-RU')}% (${Number(s.food_deficit_units||0).toLocaleString('ru-RU')} / ${Number(s.food_required_units||0).toLocaleString('ru-RU')} ед. дефицита / потребления)`}</span></div>`).join('')}<p class="hint">Обеспеченность считается после договоров и рыночного распределения. Пока это отчётный показатель: он не меняет преступность, население или производство.</p></div>`:'';
  return group('Содержание армии',`<label class="field"><span>Государство</span><select id="army-state">${states.map(s=>`<option value="${s.id}" ${Number(armyBudget.state_id)===Number(s.id)?'selected':''}>${escape(s.name)}</option>`).join('')}</select></label><div class="tool-result">Казна Короны: ${Number(armyBudget.treasury||0).toLocaleString('ru-RU')} G · Долг: ${Number(armyBudget.debt||0).toLocaleString('ru-RU')} G</div><p class="hint">Расход за ход считается как количество × содержание одного юнита. При нехватке казны оплачивается доступная сумма, остаток записывается в долг Короны. Будущие поступления Короны гасят долг перед оплатой нового содержания. Ставка типа части общая для всех государств.</p><div class="army-unit-labels"><span>Название</span><span>Количество</span><span>G / юнит за ход</span><span></span></div><div class="army-unit-list">${armyBudget.units.map((unit,index)=>`<div class="army-unit-row"><input data-army-name="${index}" value="${escape(unit.name)}" maxlength="80" placeholder="Тип части" aria-label="Тип части"><input data-army-quantity="${index}" type="number" min="0" max="1000000" step="1" value="${Number(unit.quantity)||0}" aria-label="Количество"><input data-army-upkeep="${index}" type="number" min="0" max="1000000" step="0.01" value="${Number(unit.upkeep_per_unit)||0}" aria-label="Содержание на единицу, G"><button type="button" data-army-remove="${index}" aria-label="Удалить тип части">×</button></div>`).join('')}</div><button type="button" id="army-add">Добавить тип части</button><button type="button" id="army-save" ${armyBudgetLoading?'disabled':''}>${armyBudgetDirty?'Сохранить состав и ставки':'Сохранить'}</button><button type="button" id="army-report-load">Загрузить последний отчёт хода</button>${report}<p class="hint">Расчётная стоимость: ${armyBudget.units.reduce((sum,u)=>sum+(Number(u.quantity)||0)*(Number(u.upkeep_per_unit)||0),0).toLocaleString('ru-RU')} G за ход.</p>`);
}
function categoryColorsMarkup(){
  const entries=categories.filter(c=>c.layer===colorLayer);
  const selected=entries.find(c=>c.id===Number(colorCategoryId))||entries[0];
  colorCategoryId=selected?.id??null;
  return group('Цвета параметров',`<form id="category-color-form" class="stack"><label class="field"><span>Параметр</span><select id="category-color-layer">${Object.entries(LAYERS).filter(([key])=>!['population','development'].includes(key)).map(([key,label])=>`<option value="${key}" ${key===colorLayer?'selected':''}>${label}</option>`).join('')}</select></label><label class="field"><span>Значение</span><select id="category-color-value" ${selected?'':'disabled'}>${entries.map(c=>`<option value="${c.id}" ${c.id===colorCategoryId?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label>${selected?`<label class="field"><span>Цвет</span><input id="category-color" type="color" value="${/^#[0-9a-f]{6}$/i.test(selected.color)?selected.color:'#888888'}"><output id="category-color-code">${escape(selected.color)}</output></label><button type="submit" class="primary">Сохранить цвет</button><p class="hint">Цвет изменится во всех провинциях с этим значением.</p>`:'<p class="hint">Значения этого параметра ещё не созданы.</p>'}</form>`);
}
function economyConfigMarkup(){
  const config=economyDraft||getEconomyConfig();
  const numberField=(path,label,value,step='0.01',max='1000000')=>`<label class="field economy-number"><span>${escape(label)}</span><input type="number" data-economy-path="${escape(path)}" value="${Number(value??0)}" min="0" max="${max}" step="${step}"></label>`;
  const table=(title,rows)=>group(title,`<div class="economy-config-grid">${rows.join('')}</div>`);
  const resources=(config.resources||[]).map((r,i)=>`<div class="economy-config-row"><strong>${escape(r.name)}</strong>${numberField(`resources.${i}.value`,'Ценность, G',r.value)}${numberField(`resources.${i}.production`,'Производство',r.production)}${numberField(`resources.${i}.consumption`,'Потребление',r.consumption)}</div>`);
  const types=Object.entries(config.provinceModifiers||{}).flatMap(([name,row])=>[['tax','Налоги'],['production','Производство'],['trade','Торговля'],['tradeBase','База торговли']].map(key=>numberField(`provinceModifiers.${name}.${key}`,`${name} · ${key==='tradeBase'?'База торговли':key==='tax'?'Налоговый множитель':key==='trade'?'Множитель влияния':'Множитель производства'}`,row[key])));
  const races=Object.entries(config.raceTaxRates||{}).map(([name,value])=>numberField(`raceTaxRates.${name}`,`${name} · ставка налога`,value));
  const religions=Object.entries(config.religionTaxRates||{}).map(([name,value])=>numberField(`religionTaxRates.${name}`,`${name} · ставка налога`,value));
  const trade=Object.entries(config.tradeStatusModifiers||{}).map(([name,value])=>numberField(`tradeStatusModifiers.${name}`,`${name} · множитель`,value));
  const growth=Object.entries(config.raceGrowthModifiers||{}).map(([name,value])=>numberField(`raceGrowthModifiers.${name}`,`${name} · рост населения`,value));
  const recruitGrowth=Object.entries(config.recruitGrowthModifiers||{}).map(([name,value])=>numberField(`recruitGrowthModifiers.${name}`,`${name} · прирост рекрутов`,value));
  const recruitLimit=Object.entries(config.recruitLimitModifiers||{}).map(([name,value])=>numberField(`recruitLimitModifiers.${name}`,`${name} · лимит рекрутов`,value));
  const estateRecruit=Object.entries(config.estateRecruitModifiers||{}).map(([name,value])=>numberField(`estateRecruitModifiers.${name}`,`${name} · множитель лимита рекрутов`,value));
  const valueWeights=Object.entries(config.provinceValueWeights||{}).map(([name,value])=>numberField(`provinceValueWeights.${name}`,`${({gold:'Золото',trade:'Торговля',production:'Производство',recruits:'Рекруты',population:'Население'})[name]||name} · вес`,value,'0.0001'));
  const estateTaxGreed=Object.entries(config.estateTaxGreed||{}).map(([key,value])=>{const [status,estate]=key.split('|');return numberField(`estateTaxGreed.${key}`,`${status} · ${estate} · доля сословия`,value,.01,'1');});
  return `<form id="economy-config-form" class="stack"><p class="hint">Изменения сохраняются в Supabase и используются всеми клиентами при расчётах. Коэффициент оккупации закреплён на уровне 50%. Влияние участвует в распределении дефицитных ресурсов по правилам документа «Торговля».</p>${table('Ставки налогов рас',races)}${table('Ставки налогов религий',religions)}${table('Модификаторы типов провинций',types)}${table('Распределение налогов по сословиям',estateTaxGreed)}${table('Торговые статусы',trade)}${table('Ресурсы',resources)}${table('Прирост населения',growth)}${table('Прирост рекрутов по типу провинции',recruitGrowth)}${table('Лимит рекрутов по типу провинции',recruitLimit)}${table('Лимит рекрутов по сословиям',estateRecruit)}${table('Веса ценности провинции',valueWeights)}${table('Влияние налогов на лояльность',[numberField('taxLoyaltySensitivity','Потеря лояльности на 100% превышения налога',config.taxLoyaltySensitivity,.05,'5')])}<p class="hint">Базовый налог — 0,10 G для расы и 0,10 G для религии. Каждые 10% отклонения совокупной ставки от базы меняют расчётную лояльность сословия на 5 п.п.; результат ограничен 0–100%.</p><button class="primary" type="submit">Сохранить коэффициенты</button></form>`;
}
function renderEconomyConstants(host){
  if(user?.role!=='admin'){host.innerHTML='<h3>Константы</h3><p class="hint">Раздел доступен только администратору.</p>';return;}
  host.innerHTML=`<h3>Константы</h3>${economyDraft?economyConfigMarkup():'<p class="hint">Загружаю константы экономики…</p>'}`;
  host.querySelectorAll('[data-economy-path]').forEach(input=>input.oninput=()=>{economyDirty=true;});
  const form=host.querySelector('#economy-config-form');
  if(form)form.onsubmit=async event=>{
    event.preventDefault();const config=JSON.parse(JSON.stringify(economyDraft||getEconomyConfig()));
    for(const input of form.querySelectorAll('[data-economy-path]')){
      const parts=input.dataset.economyPath.split('.');let target=config;
      for(const part of parts.slice(0,-1))target=target[Array.isArray(target)?Number(part):part];
      target[Array.isArray(target)?Number(parts.at(-1)):parts.at(-1)]=Number(input.value);
    }
    const button=form.querySelector('[type="submit"]');button.disabled=true;
    try{
      const result=await api('admin/economy/config',{method:'PATCH',body:JSON.stringify({config})});
      economyDraft=result.config;economyDirty=false;setEconomyConfig(result.config);emit('map:refresh');showStatus('Константы сохранены',3000);
    }catch(error){showStatus(error.message,5000);}finally{if(button.isConnected)button.disabled=false;}
  };
  if(!economyDraft&&!economyLoading){
    economyLoading=true;
    api('admin/economy/config').then(config=>{economyDraft=config;economyDirty=false;setEconomyConfig(config);if(host.isConnected&&activeMenuSection==='Константы')renderEconomyConstants(host);})
      .catch(error=>{if(host.isConnected)host.innerHTML=`<h3>Константы</h3><p class="form-message">${escape(error.message)}</p>`;})
      .finally(()=>economyLoading=false);
  }
}
export let settings={layer:'states',showIds:false,markers:{names:true,...Object.fromEntries(Object.keys(MARKERS).map(k=>[k,true]))},information:Object.fromEntries(Object.keys(INFO).map(k=>[k,false]))};
try{const saved=JSON.parse(localStorage.getItem('fauxlore.map-settings')||'{}');settings={...settings,...saved,markers:{...settings.markers,...saved.markers},information:{...settings.information,...saved.information}};}catch{}
if(!LAYERS[settings.layer])settings.layer='states';
export const isAdminEditing=()=>adminEditing&&user?.role==='admin';
export const isAdmin=()=>user?.role==='admin';
export const isAdminPainting=()=>paintActive&&isAdminEditing();
export const canRenameProvince=stateId=>!!user&&stateId!=null&&user.state_ids?.includes(Number(stateId));
export const getCategories=()=>categories;
export function api(path,options={}){return supabaseApi(path,options);}
export function loadInitialMap(){return loadSupabaseInitialMap();}
function save(){
  try{localStorage.setItem('fauxlore.map-settings',JSON.stringify(settings));}catch{}
  emit('map:settings',settings); clearTimeout(saveTimer);
  if(user)saveTimer=setTimeout(()=>api('preferences',{method:'PUT',body:JSON.stringify(settings)}).catch(e=>showStatus(e.message,4000)),600);
}
function updateDockState(){document.querySelectorAll('.dock-button').forEach(b=>{const active=b.dataset.panel==='legend'?legendOpen:b.dataset.panel===current;b.classList.toggle('active',active);b.setAttribute('aria-expanded',String(active));});document.body.classList.toggle('legend-open',legendOpen);}
function closeDrawer(){current=null;$('drawer').hidden=true;updateDockState();queueLayout();}
function closeLegend(){legendOpen=false;$('legend-drawer').hidden=true;updateDockState();queueLayout();}
function closeAllDrawers(){closeDrawer();closeLegend();}
function openModal(title,auth=false){closeAllDrawers();$('modal-title').textContent=title;$('modal').classList.toggle('auth-dialog',auth);$('modal').classList.toggle('menu-dialog',title==='Меню');if(!$('modal').open)$('modal').showModal();}
const checks=(entries,values,group)=>Object.entries(entries).map(([key,label])=>`<label class="check-row"><span>${label}</span><input type="checkbox" data-group="${group}" data-key="${key}" ${values[key]?'checked':''}></label>`).join('');
const group=(title,content)=>`<section class="panel-group" data-page-title="${title}">${content}</section>`;
function markerCreateMarkup(){
  const stateOptions=categories.filter(c=>c.layer==='states').map(c=>`<option value="${c.id}">${escape(c.name)}</option>`).join('');
  const markerRows=mapMarkers.map(m=>`<div class="marker-admin-row"><span>${escape(MARKERS[m.type]||m.type)} · ${escape(m.name)} · ID ${m.province_id}</span><button type="button" data-delete-marker="${m.id}" aria-label="Удалить маркер ${escape(m.name)}">×</button></div>`).join('');
  return `<section class="panel-group" data-page-title="Создать маркер"><h3>Новый маркер</h3><p id="marker-province" class="hint">Заполните поля, затем укажите точку на карте.</p><form id="marker-create-form" class="stack"><label class="field"><span>Тип</span><select name="type">${Object.entries(MARKERS).map(([key,label])=>`<option value="${key}">${label}</option>`).join('')}</select></label><label class="field"><span>Название</span><input name="name" maxlength="120" required></label><label class="field"><span>Государство (необязательно)</span><select name="state_id"><option value="">Автоматически по провинции</option>${stateOptions}</select></label><button class="primary" type="submit">Указать точку на карте</button><button id="cancel-marker-placement" type="button" hidden>Отмена</button></form>${markerRows?`<div class="marker-admin-list">${markerRows}</div>`:''}</section>`;
}
function updateMarkerAdminList(section){
  if(!section)return;
  section.querySelector('.marker-admin-list')?.remove();
  const rows=mapMarkers;
  if(!rows.length)return;
  const list=document.createElement('div');list.className='marker-admin-list';
  list.innerHTML=rows.map(m=>`<div class="marker-admin-row"><span>${escape(MARKERS[m.type]||m.type)} · ${escape(m.name)}</span><button type="button" data-delete-marker="${m.id}" aria-label="Удалить маркер ${escape(m.name)}">×</button></div>`).join('');section.append(list);
  list.querySelectorAll('[data-delete-marker]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{await api(`admin/markers/${button.dataset.deleteMarker}`,{method:'DELETE'});emit('map:marker-deleted',Number(button.dataset.deleteMarker));showStatus('Маркер удалён',2000);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
}
const searchForm=()=>`<form id="search-form" class="stack"><label for="province-id">Поиск провинции по ID</label><div class="search-row"><input id="province-id" type="number" min="1" max="16777215" step="1" placeholder="ID" required><button type="submit">Найти</button></div></form>`;
const bulkCategoryLayer={race:'races',religion:'religions',state:'states',resource:'resources',trade:'trade',climate:'climate'};
function bulkValueControl(field,value,side,index){
  const id=`bulk-${side}-${index}`;
  if(field==='terrain_type')return `<select data-bulk-value="${side}" data-index="${index}"><option value="" ${value==null?'selected':''}>Не задано</option><option value="forest" ${value==='forest'?'selected':''}>Лес</option><option value="marsh" ${value==='marsh'?'selected':''}>Болото</option></select>`;
  if(field==='occupation')return `<select data-bulk-value="${side}" data-index="${index}"><option value="" ${value==null?'selected':''}>Не оккупирована</option>${categories.filter(c=>c.layer==='states').map(c=>`<option value="${escape(c.name)}" ${value===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
  if(field==='belonging'||field==='trade_status')return `<select data-bulk-value="${side}" data-index="${index}">${(field==='belonging'?BELONGING_VALUES:TRADE_STATUS_VALUES).map(v=>`<option value="${v}" ${value===v?'selected':''}>${v}</option>`).join('')}</select>`;
  if(bulkCategoryLayer[field]&&!(field==='state'&&side==='target')){
    const entries=categories.filter(c=>c.layer===bulkCategoryLayer[field]);
    return `<select data-bulk-value="${side}" data-index="${index}"><option value="" ${value==null?'selected':''}>Не задано</option>${entries.map(c=>`<option value="${escape(c.name)}" ${value===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
  }
  if(['capital','city'].includes(field))return `<select data-bulk-value="${side}" data-index="${index}"><option value="true" ${value===true?'selected':''}>Да</option><option value="false" ${value===false?'selected':''}>Нет</option></select>`;
  if(field==='control')return `<input data-bulk-value="${side}" data-index="${index}" type="number" min="0" max="100" step="1" value="${escape(value??100)}" placeholder="0–100%">`;
  if(['population','development'].includes(field))return `<input data-bulk-value="${side}" data-index="${index}" type="number" min="0" step="1" value="${escape(value??'')}" placeholder="Целое число">`;
  return `<input data-bulk-value="${side}" data-index="${index}" value="${escape(value??'')}" maxlength="120" placeholder="Значение">`;
}
function bulkRulesMarkup(){
  const options=BULK_FIELDS.map(([key,label])=>`<option value="${key}">${label}</option>`).join('');
  const rows=bulkRules.map((rule,index)=>`<div class="bulk-rule"><label><span>Если параметр</span><select data-bulk-field="condition" data-index="${index}">${options.replace(`value="${rule.condition_field}"`,`value="${rule.condition_field}" selected`)}</select></label><label><span>равен</span>${bulkValueControl(rule.condition_field,rule.condition_value,'condition',index)}</label><label><span>Изменить параметр</span><select data-bulk-field="target" data-index="${index}">${options.replace(`value="${rule.target_field}"`,`value="${rule.target_field}" selected`)}</select></label><label><span>на значение</span>${bulkValueControl(rule.target_field,rule.target_value,'target',index)}</label><button class="bulk-remove" data-bulk-remove="${index}" aria-label="Удалить правило">Удалить правило</button></div>`).join('');
  const preview=bulkPreview?`<div class="tool-result">${bulkPreview.rule_counts.map((n,i)=>`Правило ${i+1}: ${n.toLocaleString('ru-RU')}`).join(' · ')}<br>Всего провинций: ${bulkPreview.total.toLocaleString('ru-RU')}${bulkPreview.conflict_count?`<br>Конфликтов: ${bulkPreview.conflict_count}`:''}</div>`:'';
  return `<div class="bulk-rules">${rows}</div><div class="bulk-actions"><button id="bulk-add">Добавить правило</button><button id="bulk-preview" ${bulkBusy?'disabled':''}>Проверить охват</button><button id="bulk-apply" class="primary" ${!bulkPreview||!bulkPreview.total||bulkPreview.conflict_count||bulkBusy?'disabled':''}>Применить</button></div>${preview}<p class="hint">Применяются только сухопутные провинции в игровой области. Пересекающиеся правила с разными значениями будут остановлены.</p>`;
}
function queueLayout(){if(!layoutFrame)layoutFrame=requestAnimationFrame(()=>{layoutFrame=0;layoutPanels();});}
function layoutPanels(){
  const card=$('selection'),scale=$('map-scale');
  // Anchor to the corner. Only lift the card on narrow screens if it would
  // physically intersect the scale bar; desktop always uses 12px at both edges.
  card.style.bottom='12px';card.style.width='';
  if(!card.hidden){
    const c=card.getBoundingClientRect(),s=scale.getBoundingClientRect();
    if(c.right+8>s.left&&c.left<s.right){
      const room=s.left-24;
      if(room>=160)card.style.width=`${Math.min(310,room)}px`;
      else card.style.bottom=`${innerHeight-s.top+8}px`;
    }
  }
  const drawer=$('drawer');
  const legend=$('legend-drawer');
  if(!legend.hidden){
    const calendar=document.querySelector('.turn-badge').getBoundingClientRect();
    const overlapsCalendar=64<calendar.right+8&&64+legend.getBoundingClientRect().width>calendar.left-8;
    const top=overlapsCalendar?calendar.bottom+8:12;
    let bottom=innerHeight-12;
    const rect=legend.getBoundingClientRect(),overlaps=r=>rect.left<r.right+8&&rect.right>r.left-8;
    if(!card.hidden&&overlaps(card.getBoundingClientRect()))bottom=Math.min(bottom,card.getBoundingClientRect().top-8);
    if(overlaps(scale.getBoundingClientRect()))bottom=Math.min(bottom,scale.getBoundingClientRect().top-8);
    legend.style.top=`${top}px`;legend.style.maxHeight=`${Math.max(120,bottom-top)}px`;
  }
  if(drawer.hidden)return;
  const host=$('drawer-content'),sections=[...host.children];
  drawer.querySelector('.panel-pages')?.remove();drawer.classList.remove('paged');sections.forEach(s=>s.hidden=false);
  drawer.classList.toggle('compact',innerHeight<650);
  const maxWidth=Math.max(180,innerWidth-128);
  const available=()=>{
    const d=drawer.getBoundingClientRect(),c=card.getBoundingClientRect(),s=scale.getBoundingClientRect(),calendar=document.querySelector('.turn-badge').getBoundingClientRect();
    const overlaps=r=>d.left<r.right+8&&d.right>r.left-8;
    const top=overlaps(calendar)?calendar.bottom+8:12;
    let bottom=innerHeight-12;
    if(!card.hidden&&overlaps(c))bottom=Math.min(bottom,c.top-8);
    if(overlaps(s))bottom=Math.min(bottom,s.top-8);
    drawer.style.top=`${top}px`;
    return bottom-top;
  };
  const candidates=[];
  for(const width of [...new Set([310,380,440,520,maxWidth].map(w=>Math.min(w,maxWidth)))]){
    drawer.style.width=`${width}px`;drawer.classList.toggle('wide',width>=340);
    const space=available();candidates.push({width,space});
    if(drawer.getBoundingClientRect().height<=space)return;
  }
  // A wider panel can collide with the corner card. Prefer the width with the
  // most usable vertical space before switching to compact logical pages.
  const best=candidates.sort((a,b)=>b.space-a.space||b.width-a.width)[0];
  drawer.style.width=`${best.width}px`;drawer.classList.toggle('wide',best.width>=340);available();
  // On short/mobile viewports use pages, never a clipped or scrolling panel.
  if(sections.length>1&&current!=='admin'){
    drawer.classList.add('paged');
    const chosen=Math.min(panelPages[current]||0,sections.length-1);
    sections.forEach((section,i)=>section.hidden=i!==chosen);
    const nav=document.createElement('nav');nav.className='panel-pages';nav.setAttribute('aria-label','Разделы панели');
    sections.forEach((section,i)=>{
      const b=document.createElement('button');b.textContent=section.dataset.pageTitle||String(i+1);b.classList.toggle('active',i===chosen);b.setAttribute('aria-pressed',i===chosen);
      b.onclick=()=>{panelPages[current]=i;queueLayout();};nav.append(b);
    });
    drawer.insertBefore(nav,host);
  }
}
function renderDrawer(){
  const host=$('drawer-content');
  if(current==='control')host.innerHTML=group('Слои',`<div class="radio-list">${Object.entries(LAYERS).map(([key,label])=>`<button class="layer-choice ${settings.layer===key?'active':''}" data-layer="${key}" aria-pressed="${settings.layer===key}">${label}</button>`).join('')}</div>`);
  if(current==='markers')host.innerHTML=group('Названия',checks({names:'Названия маркеров'},settings.markers,'markers'))+group('Типы',`<div class="check-grid">${Object.entries(MARKERS).map(([key,label])=>`<label class="check-row"><span class="marker-option"><img src="assets/markers/${key}.svg" alt="">${label}</span><input type="checkbox" data-group="markers" data-key="${key}" ${settings.markers[key]?'checked':''}></label>`).join('')}</div>`);
  if(current==='info')host.innerHTML=group('Поиск',searchForm())+group('Карта',`<div class="check-grid">${checks({ids:'ID провинций'},{ids:settings.showIds},'ids')}${checks({roads:INFO.roads,routes:INFO.routes},settings.information,'information')}</div>`)+group('Подписи',`<div class="check-grid">${checks(Object.fromEntries(Object.entries(INFO).filter(([k])=>!['roads','routes'].includes(k))),settings.information,'information')}</div>`);
  if(current==='tools')host.innerHTML=group('Инструмент',`<div class="tool-grid"><button data-tool="distance" aria-pressed="${toolMode==='distance'}">Расстояние</button><button data-tool="area" aria-pressed="${toolMode==='area'}">Площадь</button><button data-tool="coordinates" aria-pressed="${toolMode==='coordinates'}">Координаты</button><button id="copy-coordinates">Копировать точку</button></div>`)+group('Измерение',`<p class="hint">Две точки — расстояние. Три и более — площадь.</p><div id="tool-result" class="tool-result">${escape(lastToolResult||'Выберите инструмент')}</div><div class="tool-actions"><button id="finish-area">Завершить</button><button id="undo-point">Отменить точку</button><button id="clear-tool">Очистить</button></div>`)+group('Переход',`<form id="coordinate-form" class="stack"><label>Перейти к координатам</label><div class="coordinate-row"><input name="x" type="number" min="0" max="9999" step="any" placeholder="X" aria-label="Координата X" required><input name="y" type="number" min="0" max="9999" step="any" placeholder="Y" aria-label="Координата Y" required></div><button type="submit">Перейти</button></form>`);
  if(current==='admin'){
    const fields=[['name','Название'],['race','Раса'],['religion','Религия'],['state','Государство'],['occupation','Оккупация'],['population','Население'],['belonging','Принадлежность'],['trade_status','Торговый статус'],['resource','Ресурс'],['trade','Торговая зона'],['development','Развитие'],['control','Контроль, %'],['climate','Климат'],['terrain_type','Тип местности'],['capital','Маркер столицы'],['city','Маркер города']];
    const field=fields.some(([key])=>key===paintField)?paintField:'climate';
    let valueControl='';
    if(['race','religion','resource','climate'].includes(field)){
      const layer={race:'races',religion:'religions',resource:'resources',trade:'trade',climate:'climate'}[field];
      valueControl=`<select id="admin-paint-value"><option value="">— очистить значение —</option>${categories.filter(c=>c.layer===layer).map(c=>`<option value="${escape(c.name)}" ${paintValue===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
    }else if(field==='occupation')valueControl=`<select id="admin-paint-value"><option value="">— снять оккупацию —</option>${categories.filter(c=>c.layer==='states').map(c=>`<option value="${escape(c.name)}" ${paintValue===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
    else if(field==='terrain_type')valueControl=`<select id="admin-paint-value"><option value="">— убрать тип местности —</option><option value="forest" ${paintValue==='forest'?'selected':''}>Лес</option><option value="marsh" ${paintValue==='marsh'?'selected':''}>Болото</option></select>`;
    else if(['capital','city'].includes(field))valueControl=`<select id="admin-paint-value"><option value="true" ${paintValue==='true'?'selected':''}>Включить</option><option value="false" ${paintValue==='false'?'selected':''}>Выключить</option></select>`;
    else if(field==='belonging'||field==='trade_status')valueControl=`<select id="admin-paint-value">${(field==='belonging'?BELONGING_VALUES:TRADE_STATUS_VALUES).map(v=>`<option value="${v}" ${paintValue===v?'selected':''}>${v}</option>`).join('')}</select>`;
    else if(field==='control')valueControl=`<input id="admin-paint-value" type="number" min="0" max="100" step="1" value="${escape(paintValue||'100')}" placeholder="0–100%">`;
    else if(['population','development'].includes(field))valueControl=`<input id="admin-paint-value" type="number" min="0" step="1" value="${escape(paintValue)}" placeholder="Целое число">`;
    else valueControl=`<input id="admin-paint-value" value="${escape(paintValue)}" maxlength="120" placeholder="${field==='state'?'Название государства':''}">`;
    host.innerHTML=markerCreateMarkup()+`<section class="panel-group" data-page-title="Ручное редактирование"><span class="badge">ADMIN</span><h3>Провинции</h3><button id="toggle-admin-edit" aria-pressed="${adminEditing}">${adminEditing?'Завершить редактирование':'Режим редактирования'}</button><p class="hint">${adminEditing?'Выберите параметр и значение, затем включите нанесение и нажимайте на сухопутные провинции.':'В режиме редактирования доступны карточка провинции и массовое нанесение значений.'}</p>${adminEditing?`<label class="field"><span>Параметр</span><select id="admin-paint-field">${fields.map(([key,label])=>`<option value="${key}" ${field===key?'selected':''}>${label}</option>`).join('')}</select></label><label class="field"><span>Значение</span>${valueControl}</label><button id="toggle-admin-paint" aria-pressed="${paintActive}">${paintActive?'Завершить нанесение':'Наносить по кликам'}</button><p class="hint">${paintActive?'Нажимайте на провинции суши. Морские провинции не изменяются.':''}</p>`:''}</section>${group('Массовое редактирование',`<p class="hint">Задайте одно или несколько правил «условие → значение». Сначала проверьте количество провинций, затем примените изменения.</p>${bulkRulesMarkup()}`)}`;
  }
  if(current==='admin'){
    const title=ADMIN_TOOLS[adminTool];
    const content=['colors','roads','army'].includes(adminTool)?null:[...host.children].find(section=>section.dataset.pageTitle===title);
    if(adminTool==='colors')host.innerHTML=categoryColorsMarkup();
    else if(adminTool==='roads')host.innerHTML=roadMarkup();
    else if(adminTool==='army')host.innerHTML=armyBudgetMarkup();
    else host.replaceChildren(content);
    const wrapper=document.createElement('div');wrapper.className='admin-tool-content';
    wrapper.append(...host.childNodes);
    host.innerHTML=`<label class="field"><span>Инструмент администратора</span><select id="admin-tool">${Object.entries(ADMIN_TOOLS).map(([key,label])=>`<option value="${key}" ${adminTool===key?'selected':''}>${label}</option>`).join('')}</select></label>`;
    host.append(wrapper);
    $('admin-tool').disabled=roadInfo.busy;
    $('admin-tool').onchange=e=>{
      if(roadInfo.active)emit('roads:cancel');
      adminTool=e.target.value;paintActive=false;adminEditing=false;pendingMarkerDraft=null;
      emit('map:admin-paint',null);emit('admin:editing',{enabled:false});emit('map:place-marker',null);
      renderDrawer();
    };
    if(adminTool==='army'){
      const loadArmyBudget=async stateId=>{
        if(!stateId)return;
        armyBudget.state_id=stateId;
        armyBudgetLoading=true;renderDrawer();
        try{armyBudget=await api(`admin/states/${stateId}/army`);armyBudgetDirty=false;}
        catch(error){showStatus(error.message,5000);}
        finally{armyBudgetLoading=false;renderDrawer();}
      };
      if($('army-state'))$('army-state').onchange=e=>loadArmyBudget(Number(e.target.value));
      if($('army-report-load'))$('army-report-load').onclick=async()=>{try{armyReport=await api('admin/turn/latest-report');renderDrawer();}catch(error){showStatus(error.message,5000);}};
      if(!armyBudget.state_id&&categories.some(c=>c.layer==='states'))loadArmyBudget(categories.find(c=>c.layer==='states').id);
      host.querySelectorAll('[data-army-name]').forEach(input=>input.onchange=()=>{armyBudget.units[Number(input.dataset.armyName)].name=input.value;armyBudgetDirty=true;});
      host.querySelectorAll('[data-army-quantity]').forEach(input=>input.onchange=()=>{armyBudget.units[Number(input.dataset.armyQuantity)].quantity=Number(input.value);armyBudgetDirty=true;});
      host.querySelectorAll('[data-army-upkeep]').forEach(input=>input.onchange=()=>{armyBudget.units[Number(input.dataset.armyUpkeep)].upkeep_per_unit=Number(input.value);armyBudgetDirty=true;});
      host.querySelectorAll('[data-army-remove]').forEach(button=>button.onclick=()=>{armyBudget.units.splice(Number(button.dataset.armyRemove),1);armyBudgetDirty=true;renderDrawer();});
      if($('army-add'))$('army-add').onclick=()=>{armyBudget.units.push({name:'',quantity:0,upkeep_per_unit:0});armyBudgetDirty=true;renderDrawer();host.querySelector(`[data-army-name="${armyBudget.units.length-1}"]`)?.focus();};
      if($('army-save'))$('army-save').onclick=async()=>{
        if(armyBudget.units.some(u=>!String(u.name||'').trim()||!Number.isInteger(Number(u.quantity))||Number(u.quantity)<0||!Number.isFinite(Number(u.upkeep_per_unit))||Number(u.upkeep_per_unit)<0)){showStatus('Заполните названия, целое количество и неотрицательную ставку для всех типов частей',5000);return;}
        armyBudgetLoading=true;renderDrawer();
        try{armyBudget=await api(`admin/states/${armyBudget.state_id}/army`,{method:'PATCH',body:JSON.stringify({units:armyBudget.units})});armyBudgetDirty=false;showStatus('Состав армии и ставки сохранены',3500);}
        catch(error){showStatus(error.message,5000);}
        finally{armyBudgetLoading=false;renderDrawer();}
      };
    }
    if($('road-type'))$('road-type').onchange=e=>{roadType=e.target.value;};
    if($('road-start'))$('road-start').onclick=()=>{settings.information.roads=true;save();emit('roads:start',roadType);};
    if($('road-cancel'))$('road-cancel').onclick=()=>emit('roads:cancel');
    if($('road-undo'))$('road-undo').onclick=()=>emit('roads:undo');
    if($('road-save'))$('road-save').onclick=()=>emit('roads:save');
    host.querySelectorAll('[data-delete-road]').forEach(button=>button.onclick=async()=>{
      if(!confirm(`Удалить дорогу № ${button.dataset.deleteRoad}?`))return;
      button.disabled=true;try{await api(`admin/roads/${button.dataset.deleteRoad}`,{method:'DELETE'});emit('map:refresh');showStatus('Дорога удалена',2500);}catch(error){button.disabled=false;showStatus(error.message,5000);}
    });
    if($('category-color-layer'))$('category-color-layer').onchange=e=>{colorLayer=e.target.value;colorCategoryId=null;renderDrawer();};
    if($('category-color-value'))$('category-color-value').onchange=e=>{colorCategoryId=Number(e.target.value);renderDrawer();};
    if($('category-color'))$('category-color').oninput=e=>{$('category-color-code').textContent=e.target.value;};
    if($('category-color-form'))$('category-color-form').onsubmit=async e=>{
      e.preventDefault();const button=e.target.querySelector('[type="submit"]');if(!button)return;
      const layer=colorLayer,id=colorCategoryId,color=$('category-color').value;
      button.disabled=true;
      try{await api(`admin/categories/${layer}/${id}`,{method:'PATCH',body:JSON.stringify({color})});emit('map:refresh');showStatus('Цвет сохранён',2500);}
      catch(error){showStatus(error.message,5000);}finally{if(button.isConnected)button.disabled=false;}
    };
  }
  if($('marker-create-form')){
    const form=$('marker-create-form');
    updateMarkerAdminList(form.closest('.panel-group'));
    form.onsubmit=event=>{event.preventDefault();const name=form.elements.name.value.trim();if(!name){showStatus('Укажите название маркера',3000);return;}pendingMarkerDraft={type:form.elements.type.value,name};if(form.elements.state_id.value)pendingMarkerDraft.state_id=Number(form.elements.state_id.value);form.querySelector('button[type="submit"]').textContent='Щёлкните по нужной точке карты…';form.querySelector('button[type="submit"]').disabled=true;$('cancel-marker-placement').hidden=false;emit('map:place-marker',pendingMarkerDraft);};
    $('cancel-marker-placement').onclick=()=>{pendingMarkerDraft=null;form.querySelector('button[type="submit"]').textContent='Указать точку на карте';form.querySelector('button[type="submit"]').disabled=false;$('cancel-marker-placement').hidden=true;$('marker-province').textContent='Заполните поля, затем укажите точку на карте.';emit('map:place-marker',null);};
  }
  host.querySelectorAll('[data-layer]').forEach(b=>b.onclick=()=>{settings.layer=b.dataset.layer;save();renderDrawer();renderLegend();});
  if($('toggle-admin-edit'))$('toggle-admin-edit').onclick=()=>{adminEditing=!adminEditing;if(!adminEditing){paintActive=false;emit('map:admin-paint',null);}emit('admin:editing',{enabled:adminEditing});renderDrawer();};
  if($('admin-paint-field'))$('admin-paint-field').onchange=e=>{if(paintActive){paintActive=false;emit('map:admin-paint',null);}paintField=e.target.value;paintValue=({capital:'true',city:'true',control:'100'}[paintField]||'');renderDrawer();};
  if($('admin-paint-value'))$('admin-paint-value').onchange=e=>{if(paintActive){paintActive=false;emit('map:admin-paint',null);const button=$('toggle-admin-paint');button.textContent='Наносить по кликам';button.setAttribute('aria-pressed','false');}paintValue=e.target.value;};
  if($('toggle-admin-paint'))$('toggle-admin-paint').onclick=()=>{const input=$('admin-paint-value');paintValue=input.value;if(['name','state'].includes(paintField)&&!paintValue.trim()){showStatus('Введите значение параметра',3000);return;}if(paintField==='control'&&(!Number.isInteger(Number(paintValue))||Number(paintValue)<0||Number(paintValue)>100)){showStatus('Контроль должен быть целым числом от 0 до 100',3000);return;}paintActive=!paintActive;emit('map:admin-paint',paintActive?{field:paintField,value:['population','development','control'].includes(paintField)?Number(paintValue):['capital','city'].includes(paintField)?paintValue==='true':['terrain_type','occupation'].includes(paintField)?(paintValue||null):paintValue}:null);renderDrawer();};
  host.querySelectorAll('[data-bulk-field]').forEach(select=>select.onchange=()=>{const index=Number(select.dataset.index),side=select.dataset.bulkField,field=select.value;bulkRules[index][`${side}_field`]=field;bulkRules[index][`${side}_value`]=field==='belonging'||field==='trade_status'?'Отсутствует':['capital','city'].includes(field)?true:['population','development'].includes(field)?0:null;bulkPreview=null;renderDrawer();});
  host.querySelectorAll('[data-bulk-value]').forEach(input=>input.onchange=()=>{const index=Number(input.dataset.index),side=input.dataset.bulkValue,field=bulkRules[index][`${side}_field`];let value=input.value;if(['population','development','control'].includes(field))value=Number(value);else if(['capital','city'].includes(field))value=value==='true';else if(value==='')value=null;bulkRules[index][`${side}_value`]=value;bulkPreview=null;renderDrawer();});
  host.querySelectorAll('[data-bulk-remove]').forEach(button=>button.onclick=()=>{if(bulkRules.length===1){showStatus('Добавьте другое правило перед удалением этого',3000);return;}bulkRules.splice(Number(button.dataset.bulkRemove),1);bulkPreview=null;renderDrawer();});
  if($('bulk-add'))$('bulk-add').onclick=()=>{bulkRules.push({condition_field:'climate',condition_value:null,target_field:'population',target_value:0});bulkPreview=null;renderDrawer();};
  if($('bulk-preview'))$('bulk-preview').onclick=async()=>{bulkBusy=true;renderDrawer();try{bulkPreview=await api('admin/provinces/bulk-preview',{method:'POST',body:JSON.stringify({rules:bulkRules})});}catch(error){showStatus(error.message,5000);}finally{bulkBusy=false;renderDrawer();}};
  if($('bulk-apply'))$('bulk-apply').onclick=async()=>{if(!bulkPreview||bulkPreview.conflict_count||!bulkPreview.total)return;if(!confirm(`Применить правила к ${bulkPreview.total.toLocaleString('ru-RU')} провинциям?`))return;bulkBusy=true;renderDrawer();try{const result=await api('admin/provinces/bulk-edit',{method:'POST',body:JSON.stringify({rules:bulkRules})});bulkPreview=null;emit('map:refresh');showStatus(`Обновлено провинций: ${result.updated_count.toLocaleString('ru-RU')}`,5000);}catch(error){showStatus(error.message,5000);}finally{bulkBusy=false;renderDrawer();}};
  host.querySelectorAll('input[data-group]').forEach(input=>input.onchange=()=>{if(input.dataset.group==='ids')settings.showIds=input.checked;else settings[input.dataset.group][input.dataset.key]=input.checked;save();});
  if($('search-form'))$('search-form').onsubmit=e=>{e.preventDefault();emit('map:search',Number($('province-id').value));};
  host.querySelectorAll('[data-tool]').forEach(b=>b.onclick=()=>{toolMode=toolMode===b.dataset.tool?'':b.dataset.tool;panelPages.tools=toolMode?1:0;emit('map:tool',toolMode);renderDrawer();});
  if($('finish-area')){
    $('finish-area').onclick=()=>emit('map:finish');$('clear-tool').onclick=()=>emit('map:clear-tool');$('undo-point').onclick=()=>emit('map:undo');
    $('copy-coordinates').onclick=()=>emit('map:copy-coordinates');
    $('coordinate-form').onsubmit=e=>{e.preventDefault();const data=new FormData(e.target);emit('map:coordinate',[Number(data.get('x')),Number(data.get('y'))]);};
  }
  queueLayout();
}
function renderLegend(){
  if(!legendOpen)return;
  const host=$('legend-content'),entries=categories.filter(c=>c.layer===settings.layer);
  let html=`<h3>${LAYERS[settings.layer]}</h3>`;
  if(entries.length)html+=entries.map(c=>`<div class="legend-row"><i class="legend-swatch" style="background:${/^#[0-9a-f]{6}$/i.test(c.color)?c.color:'#888'}"></i><span>${escape(c.name)}</span></div>`).join('');
  else if(['population','development'].includes(settings.layer)){
    const values=allProvinces.map(p=>settings.layer==='population'?(p.kind==='land'&&p.population!=null?Number(p.population):null):p.development).filter(v=>v!=null);
    html+=values.length?`<p>${settings.layer==='population'?'Население провинций: ':''}от ${Math.min(...values).toLocaleString('ru-RU')} до ${Math.max(...values).toLocaleString('ru-RU')}${settings.layer==='population'?' чел.':''}</p><div class="gradient-key"></div>`:'<p class="hint">Показатели пока не заполнены.</p>';
  }else html+='<p class="hint">Для выбранного слоя данные пока не назначены.</p>';
  host.innerHTML=group('Слой',html)+group('Местность','<div class="legend-row"><i class="terrain-swatch forest"></i><span>Лес</span></div><div class="legend-row"><i class="terrain-swatch marsh"></i><span>Болото</span></div>')+group('Территории','<div class="legend-row"><i class="legend-swatch" style="background:#ffe7d6"></i><span>Нейтральные территории</span></div><div class="legend-row"><i class="legend-swatch" style="background:#486370"></i><span>Море</span></div><div class="legend-row"><i class="legend-swatch" style="background:#1f87ad"></i><span>Озеро</span></div>');
  queueLayout();
}
function togglePanel(key){
  if(key==='auth'){renderAuth();return;}
  if(key==='menu'){renderMenu('Профиль');return;}
  if(key==='admin'&&user?.role!=='admin')return;
  if(key==='legend'){
    legendOpen=!legendOpen;$('legend-drawer').hidden=!legendOpen;
    if(legendOpen)renderLegend();updateDockState();queueLayout();return;
  }
  if(current===key){closeDrawer();return;}
  current=key;$('drawer-title').textContent=PANELS[key][0];$('drawer').className=`surface drawer ${PANELS[key][2]}`;$('drawer').hidden=false;
  updateDockState();renderDrawer();
}
async function acceptUser(next){
  user=next;notificationFetchToken++;unreadNotificationCount=0;updateNotificationBadge();$('advance-turn').hidden=user?.role!=='admin';if(user?.role!=='admin'){adminEditing=false;paintActive=false;emit('map:admin-paint',null);emit('roads:cancel');}$('panel-admin').hidden=user?.role!=='admin';$('panel-auth').title=user?`Авторизация · ${user.nickname}`:'Авторизация';
  if(!user&&current==='admin')closeDrawer();
  if(user){void refreshUnreadNotificationCount();try{const stored=await api('preferences');settings={...settings,...stored,markers:{...settings.markers,...stored.markers},information:{...settings.information,...stored.information}};if(!LAYERS[settings.layer])settings.layer='states';save();}catch(e){showStatus(e.message,4000);}}
}
function renderAuth(){
  openModal('Авторизация',true);const host=$('modal-content');
  if(user){
    host.innerHTML=`<div class="stack"><h3>${escape(user.nickname)}</h3><p>${escape(user.email)}</p><p class="hint">Роль: ${escape(user.role)}</p><button id="logout">Выйти</button></div>`;
    $('logout').onclick=async()=>{try{await api('auth/logout',{method:'POST',body:'{}'});await acceptUser(null);renderAuth();}catch(e){showStatus(e.message,4000);}};return;
  }
  host.innerHTML='<div class="stack"><button id="google-login" class="primary">Войти через Google</button><p class="hint">При первом входе игровой аккаунт создаётся автоматически.</p><p id="auth-message" class="hint" role="status"></p></div>';
  $('google-login').onclick=async()=>{const button=$('google-login');button.disabled=true;try{const result=await supabaseLogin();await acceptUser(result.user);$("modal").close();showStatus(`Вы вошли как ${result.user.nickname}`,3000);}catch(error){$('auth-message').textContent=error.message;}finally{button.disabled=false;}};
}
async function renderProfile(host,showApplicationForm=false){
  if(!user){host.innerHTML='<h3>Профиль</h3><p class="hint">Войдите или зарегистрируйтесь, чтобы управлять профилем.</p><button id="profile-login">Войти</button>';host.querySelector('#profile-login').onclick=()=>renderAuth();return;}
  if(showApplicationForm||applicationDraft){renderApplicationForm(host);return;}
  host.innerHTML='<p class="hint">Загружаю профиль…</p>';
  try{
    const [profile,applications]=await Promise.all([api('profile'),api('my/applications')]);if(!host.isConnected)return;
    const pending=applications.find(item=>item.status==='На рассмотрении');
    const avatar=profile.avatar_url?`<img class="profile-avatar" src="${escape(profile.avatar_url)}${profile.avatar_url.startsWith('data:')?'':`?v=${Date.now()}`}" alt="Аватар">`:`<span class="profile-avatar profile-avatar-fallback">${escape(profile.nickname.slice(0,1).toUpperCase())}</span>`;
    host.innerHTML=`<div class="profile-card">${avatar}<div><h3>${escape(profile.nickname)}</h3><p class="hint">${escape(profile.email||'')} · ${profile.role==='admin'?'Администратор':'Игрок'}</p><p>Репутация: <strong>${profile.reputation}</strong></p></div></div><div class="profile-avatar-actions"><label class="profile-avatar-upload">${profile.avatar_url?'Сменить аватар':'Загрузить аватар'}<input id="profile-avatar-file" type="file" accept="image/png,image/jpeg,image/gif,image/webp" hidden></label>${profile.avatar_url?'<button id="profile-avatar-delete">Удалить аватар</button>':''}<span class="hint">PNG, JPEG, GIF или WebP · до 2 МБ</span></div>${profile.role==='admin'?'<section class="application-panel"><h3>Модерация</h3><button id="admin-applications">Анкеты игроков</button></section>':''}${profile.role!=='admin'&&!profile.state_ids?.length?`<section class="application-panel"><h3>Государство</h3>${pending?`<p>Анкета «${escape(pending.state_name)}» — <strong>На рассмотрении</strong></p><button data-open-application="${pending.id}">Открыть анкету</button>`:`<button id="create-application" class="primary">Создать государство</button>`}${applications.filter(item=>item.status!=='На рассмотрении').map(item=>`<button class="application-history" type="button" data-open-application="${item.id}">${escape(item.state_name)} — ${escape(item.status)}</button>`).join('')}</section>`:''}${applications.some(item=>item.status==='Принято')?`<p>Ваше государство: <strong>${escape(applications.find(item=>item.status==='Принято').state_name)}</strong></p>`:''}`;
    const avatarImage=host.querySelector('.profile-avatar');if(avatarImage)avatarImage.onerror=()=>{const fallback=document.createElement('span');fallback.className='profile-avatar profile-avatar-fallback';fallback.textContent=profile.nickname.slice(0,1).toUpperCase();avatarImage.replaceWith(fallback);};
    host.querySelector('#profile-avatar-file').onchange=async event=>{const file=event.target.files?.[0];if(!file)return;if(file.size>2*1024*1024){showStatus('Аватар должен быть не больше 2 МБ',4000);return;}try{const image_data=await readImageData(file);await api('profile/avatar',{method:'POST',body:JSON.stringify({image_data})});showStatus('Аватар обновлён',2500);renderProfile(host);}catch(error){showStatus(error.message,5000);}};
    host.querySelector('#profile-avatar-delete')?.addEventListener('click',async()=>{try{await api('profile/avatar',{method:'POST',body:JSON.stringify({image_data:null})});showStatus('Аватар удалён',2500);renderProfile(host);}catch(error){showStatus(error.message,5000);}});
    host.querySelector('#create-application')?.addEventListener('click',()=>{applicationDraft={province_ids:[],principles:Object.fromEntries(Object.entries(PRINCIPLES).map(([key,values])=>[key,values[0]])),state_color:'#657e91'};renderProfile(host,true);});
    host.querySelector('#admin-applications')?.addEventListener('click',()=>renderAdminApplications(host));
    host.querySelectorAll('[data-open-application]').forEach(button=>button.onclick=()=>showApplication(host,applications.find(item=>String(item.id)===button.dataset.openApplication)));
  }catch(error){host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}
function applicationIsConnected(ids){
  if(ids.length!==5||new Set(ids.map(Number)).size!==5)return false;
  const selected=new Set(ids.map(Number));
  const linked=(a,b)=>(provinceAdjacency[a]||[]).includes(b)||(provinceAdjacency[a]||[]).some(mid=>!selected.has(Number(mid))&&allProvinces.find(p=>p.id===Number(mid))?.kind==='sea'&&(provinceAdjacency[mid]||[]).includes(b));
  const reached=new Set([Number(ids[0])]),queue=[...reached];
  while(queue.length){const a=queue.shift();for(const b of selected)if(!reached.has(b)&&linked(a,b)){reached.add(b);queue.push(b);}}
  return reached.size===5;
}
function applicationColorConflicts(color,ids){
  const rgb=value=>String(value||'').match(/^#([\da-f]{2})([\da-f]{2})([\da-f]{2})$/i)?.slice(1).map(part=>parseInt(part,16));
  const chosen=rgb(color);if(!chosen)return false;
  const neighbors=new Set(ids.flatMap(id=>provinceAdjacency[id]||[]));
  return [...neighbors].some(id=>{const sid=Number(allProvinces.find(p=>p.id===Number(id))?.layers?.states?.id);const other=rgb(categories.find(c=>c.layer==='states'&&c.id===sid)?.color);return other&&Math.hypot(chosen[0]-other[0],chosen[1]-other[1],chosen[2]-other[2])<70;});
}
function renderApplicationForm(host){
  const d=applicationDraft;
  const principles=Object.entries(PRINCIPLES).map(([key,values])=>`<label class="field"><span>${({authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина',ephemeral:'Эфемерный вопрос'})[key]}</span><select name="${key}">${values.map(value=>`<option ${d.principles[key]===value?'selected':''}>${escape(value)}</option>`).join('')}</select></label>`).join('');
  const provinceLabels=d.province_ids.map(id=>allProvinces.find(p=>p.id===Number(id))?.name||`ID ${id}`).join(', ');
  host.innerHTML=`<form id="player-application-form" class="application-form stack"><h3>Анкета государства</h3><label class="field"><span>Название государства</span><input name="state_name" maxlength="100" required value="${escape(d.state_name||'')}"></label><label class="field"><span>Цвет на карте</span><input name="state_color" type="color" value="${escape(d.state_color||'#657e91')}"></label>${principles}<label class="field"><span>Имя правителя</span><input name="ruler_name" maxlength="100" required value="${escape(d.ruler_name||'')}"></label><label class="field"><span>Фамилия правителя</span><input name="ruler_surname" maxlength="120" required value="${escape(d.ruler_surname||'')}"></label><label class="field"><span>Пол правителя</span><select name="ruler_gender"><option>Мужской</option><option ${d.ruler_gender==='Женский'?'selected':''}>Женский</option></select></label><label class="field"><span>Титул правителя</span><input name="ruler_title" maxlength="100" required value="${escape(d.ruler_title||'')}"></label><label class="field"><span>Возраст правителя (от 30)</span><input name="ruler_age" type="number" min="30" required value="${escape(d.ruler_age||30)}"></label><label class="field"><span>Официальная раса</span><select name="race_id">${categories.filter(c=>c.layer==='races').map(c=>`<option value="${c.id}" ${Number(d.race_id)===c.id?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>Официальная религия</span><select name="religion_id">${categories.filter(c=>c.layer==='religions').map(c=>`<option value="${c.id}" ${Number(d.religion_id)===c.id?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>История и описание (<output id="history-count">${(d.history||'').length}</output>/1500–4000)</span><textarea name="history" minlength="1500" maxlength="4000" rows="8" required>${escape(d.history||'')}</textarea></label><section class="application-panel"><h3>Территория и столица</h3><p>${d.province_ids.length}/5 выбрано${provinceLabels?`: ${escape(provinceLabels)}`:''}</p><button id="pick-application-provinces" type="button">Выбрать провинции на карте</button><button id="pick-application-capital" type="button" ${d.province_ids.length!==5?'disabled':''}>${d.capital_province_id?'Изменить провинцию столицы':'Выбрать столицу на карте'}</button><p>Столица: ${escape(allProvinces.find(p=>p.id===Number(d.capital_province_id))?.name||'не выбрана')}</p><label class="field"><span>Название столицы</span><input name="capital_name" maxlength="120" required value="${escape(d.capital_name||'')}"></label></section><label class="field"><span>Флаг / символика (JPG, JPEG, PNG или WebP, до 2 МБ)</span><input id="application-emblem" type="file" accept="image/jpeg,image/png,image/webp" ${d.emblem_data?'':'required'}></label>${d.emblem_data?`<img class="application-emblem-preview" src="${d.emblem_data}" alt="Предпросмотр символики">`:''}<label class="check-row"><span>Я изучил Правила и Механики проекта</span><input name="rules_acknowledged" type="checkbox" required ${d.rules_acknowledged?'checked':''}></label><p id="application-form-message" class="form-message" role="status"></p><button class="primary" type="submit">Отправить анкету</button><button id="cancel-application" type="button">Отмена</button></form>`;
  const form=host.querySelector('#player-application-form');
  const emblemInput=form.querySelector('#application-emblem');
  if(d.emblem_data){emblemInput.hidden=true;const label=emblemInput.closest('label');const status=document.createElement('p');status.className='hint';status.textContent=`Загружено: ${d.emblem_file_name||'изображение символики'}`;const replace=document.createElement('button');replace.type='button';replace.textContent='Заменить изображение';replace.onclick=()=>emblemInput.click();label.append(status,replace);}
  const governmentPreview=document.createElement('section');governmentPreview.className='application-panel';governmentPreview.innerHTML='<h3>Форма правления</h3><p class="government-preview" role="status"></p>';
  form.elements.ephemeral.closest('.field').after(governmentPreview);
  const updateGovernmentPreview=()=>{const selection=Object.fromEntries(Object.keys(PRINCIPLES).map(key=>[key,form.elements[key].value]));const problem=principleConflict(selection),preview=governmentPreview.querySelector('.government-preview');preview.textContent=problem||governmentName(selection)||'Не удалось определить форму правления';preview.classList.toggle('invalid',!!problem);};
  Object.keys(PRINCIPLES).forEach(key=>form.elements[key].addEventListener('change',updateGovernmentPreview));updateGovernmentPreview();
  form.querySelector('[name=history]').oninput=e=>{d.history=e.target.value;host.querySelector('#history-count').value=e.target.value.length;};
  form.querySelectorAll('input,select').forEach(el=>el.addEventListener('change',()=>{if(el.name)d[el.name]=el.type==='checkbox'?el.checked:el.value;if(el.name in PRINCIPLES)d.principles[el.name]=el.value;if(el.name==='state_color')d.state_color=el.value;}));
  emblemInput.onchange=async e=>{const file=e.target.files?.[0];if(!file)return;if(file.size>2097152||!['image/jpeg','image/png','image/webp'].includes(file.type)){host.querySelector('#application-form-message').textContent='Нужен JPG, PNG или WebP до 2 МБ.';e.target.value='';return;}d.emblem_data=await readImageData(file);d.emblem_file_name=file.name;renderApplicationForm(host);};
  form.querySelector('#pick-application-provinces').onclick=()=>{applicationPickMode='provinces';emit('application:pick',{mode:'provinces',ids:d.province_ids});$('modal').close();showStatus('Выберите пять свободных сухопутных провинций. Повторный щелчок снимает выбор.',0);};
  form.querySelector('#pick-application-capital').onclick=()=>{applicationPickMode='capital';emit('application:pick',{mode:'capital',ids:d.province_ids});$('modal').close();showStatus('Выберите одну из пяти выбранных провинций для столицы.',0);};
  form.querySelector('#cancel-application').onclick=()=>{applicationDraft=null;applicationPickMode=null;emit('application:pick',null);emit('application:clear-selection');renderProfile(host);};
  form.onsubmit=async e=>{e.preventDefault();const data=Object.fromEntries(new FormData(form));Object.assign(d,data,{principles:Object.fromEntries(Object.keys(PRINCIPLES).map(key=>[key,data[key]]))});
    const hasTradeZone=d.province_ids.every(id=>!!allProvinces.find(province=>Number(province.id)===Number(id))?.layers?.trade);
    const problem=principleConflict(d.principles)||(!hasTradeZone?'У каждой выбранной провинции должна быть назначена торговая зона.':'')||(!applicationIsConnected(d.province_ids)?'Провинции должны соседствовать напрямую или через одну морскую провинцию.':'')||(applicationColorConflicts(d.state_color,d.province_ids)?'Выберите цвет, заметно отличающийся от цветов соседних государств.':'')||(!d.capital_province_id?'Выберите провинцию столицы.':'')||(!d.emblem_data?'Загрузите символику государства.':'')||(!data.rules_acknowledged?'Подтвердите ознакомление с Правилами и Механиками.':'');
    if(problem){host.querySelector('#application-form-message').textContent=problem;return;}
    const submit=form.querySelector('[type=submit]');submit.disabled=true;
    const payload={state_name:data.state_name,state_color:data.state_color,principles:d.principles,ruler_name:data.ruler_name,ruler_surname:data.ruler_surname,ruler_gender:data.ruler_gender,ruler_title:data.ruler_title,ruler_age:Number(data.ruler_age),race_id:Number(data.race_id),religion_id:Number(data.religion_id),history:data.history,province_ids:d.province_ids.map(Number),capital_province_id:Number(d.capital_province_id),capital_name:data.capital_name,emblem_data:d.emblem_data,rules_acknowledged:!!data.rules_acknowledged};
    try{await api('my/applications',{method:'POST',body:JSON.stringify(payload)});applicationDraft=null;emit('application:clear-selection');showStatus('Анкета отправлена на рассмотрение',3500);emit('map:refresh');renderProfile(host);}
    catch(error){host.querySelector('#application-form-message').textContent=error.message;submit.disabled=false;}
  };
}
async function showApplication(host,summary){
  if(!summary)return;host.innerHTML='<p class="hint">Загружаю анкету…</p>';
  try{const item=await api(`my/applications/${summary.id}`);if(!host.isConnected)return;
    const labels={authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина',ephemeral:'Эфемерный вопрос'};
    const principles=Object.entries(item.principles).map(([key,value])=>`<p><strong>${labels[key]||escape(key)}:</strong> ${escape(value)}</p>`).join('');
    const provinces=item.province_ids.map(id=>escape(allProvinces.find(p=>p.id===Number(id))?.name||`ID ${id}`)).join(', ');
    const race=categories.find(c=>c.layer==='races'&&c.id===Number(item.race_id))?.name||'—',religion=categories.find(c=>c.layer==='religions'&&c.id===Number(item.religion_id))?.name||'—';
    host.innerHTML=`<article class="application-panel"><h3>${escape(item.state_name)} — ${escape(item.status)}</h3><div class="state-color" style="background:${escape(item.state_color)}" aria-label="Цвет государства"></div><h4>Принципы государства</h4>${principles}<h4>Правитель</h4><p>${escape(item.ruler_name)} · ${escape(item.ruler_gender)} · ${escape(item.ruler_title)} · ${item.ruler_age} лет</p><h4>Официальные ценности</h4><p>Раса: ${escape(race)} · религия: ${escape(religion)}</p><h4>Территория и столица</h4><p>${provinces}</p><p>${escape(item.capital_name)} · ID провинции ${item.capital_province_id}</p><h4>Символика</h4><img class="application-emblem-preview" src="data:${item.emblem_type};base64,${item.emblem_base64}" alt="Символика государства"><h4>История и описание (${item.history.length} знаков)</h4><p class="application-history-text">${escape(item.history)}</p>${item.status==='Отклонено'?`<div class="form-message">Причина отклонения: ${escape(item.rejection_reason||'не указана')}</div>`:''}<button id="application-back">Назад в профиль</button></article>`;
    host.querySelector('#application-back').onclick=()=>renderProfile(host);
  }catch(error){host.innerHTML=`<p class="form-message">${escape(error.message)}</p><button id="application-back">Назад в профиль</button>`;host.querySelector('#application-back').onclick=()=>renderProfile(host);}
}
async function renderAdminApplications(host){
  host.innerHTML='<p class="hint">Загружаю анкеты…</p>';
  try{const rows=await api('admin/applications');if(!host.isConnected)return;host.innerHTML=`<div class="application-review stack"><h3>Анкеты игроков</h3>${rows.length?rows.map(x=>`<article class="application-panel"><h3>${escape(x.state_name)}</h3><p>Автор: ${escape(x.applicant_nickname)} · ${escape(x.applicant_email)}</p><p>${escape(x.ruler_title)} ${escape(x.ruler_name)} · ${x.ruler_gender}, ${x.ruler_age} лет</p><p>${Object.values(x.principles).map(escape).join(' · ')}</p><p>Столица: ${escape(x.capital_name)} · провинция ${x.capital_province_id}</p><p>Территории: ${x.province_ids.map(id=>escape(allProvinces.find(p=>p.id===Number(id))?.name||`ID ${id}`)).join(', ')}</p><img class="application-emblem-preview" src="data:${x.emblem_type};base64,${x.emblem_base64}" alt="Символика"><details><summary>История (${x.history.length} символов)</summary><p>${escape(x.history)}</p></details><textarea data-reason="${x.id}" maxlength="1000" placeholder="Причина отказа" rows="2"></textarea><div class="application-actions"><button class="primary" data-accept="${x.id}">Принять</button><button class="danger-button" data-reject="${x.id}">Отклонить</button></div></article>`).join(''):'<p class="hint">Нет заявок на рассмотрении.</p>'}<button id="application-back">Назад в профиль</button></div>`;
    host.querySelectorAll('[data-accept]').forEach(b=>b.onclick=async()=>{if(!confirm('Принять анкету и создать государство?'))return;b.disabled=true;try{await api(`admin/applications/${b.dataset.accept}`,{method:'PATCH',body:JSON.stringify({status:'Принято'})});emit('map:refresh');showStatus('Государство создано',3000);renderAdminApplications(host);}catch(e){b.disabled=false;showStatus(e.message,5000);}});
    host.querySelectorAll('[data-reject]').forEach(b=>b.onclick=async()=>{b.disabled=true;try{await api(`admin/applications/${b.dataset.reject}`,{method:'PATCH',body:JSON.stringify({status:'Отклонено',rejection_reason:host.querySelector(`[data-reason="${b.dataset.reject}"]`).value})});emit('map:refresh');showStatus('Анкета отклонена',2500);renderAdminApplications(host);}catch(e){b.disabled=false;showStatus(e.message,5000);}});
    host.querySelector('#application-back').onclick=()=>renderProfile(host);
  }catch(error){host.innerHTML=`<p class="form-message">${escape(error.message)}</p><button id="application-back">Назад</button>`;host.querySelector('#application-back').onclick=()=>renderProfile(host);}
}
async function renderNotifications(host){
  host.innerHTML='<p class="hint">Загружаю уведомления…</p>';
  try{const requestedUser=user,rows=await api('notifications');if(!host.isConnected||user!==requestedUser)return;setUnreadNotificationCount(rows);host.innerHTML=`<div class="notification-list stack"><h3>Уведомления</h3>${rows.length?rows.map(x=>`<article class="application-panel"><strong>${escape(x.title)}</strong><p>${escape(x.message)}</p><small>${new Date(x.created_at).toLocaleString('ru-RU')}</small>${x.read?'':`<button data-read-notification="${x.id}">Отметить прочитанным</button>`}</article>`).join(''):'<p class="hint">Уведомлений пока нет.</p>'}</div>`;host.querySelectorAll('[data-read-notification]').forEach(b=>b.onclick=async()=>{try{await api(`notifications/${b.dataset.readNotification}/read`,{method:'PATCH',body:'{}'});renderNotifications(host);}catch(e){showStatus(e.message,4000);}});}
  catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}
function readImageData(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error('Не удалось прочитать изображение'));reader.readAsDataURL(file);});}
function updateNotificationBadge(){
  document.querySelectorAll('.menu-tabs [data-section="Уведомления"]').forEach(button=>{
    let badge=button.querySelector('.notification-indicator');
    if(unreadNotificationCount>0){if(!badge){badge=document.createElement('span');badge.className='notification-indicator';badge.textContent='!';badge.setAttribute('aria-hidden','true');button.append(badge);}button.setAttribute('aria-label',`Уведомления: ${unreadNotificationCount} непрочитанных`);}
    else{badge?.remove();button.removeAttribute('aria-label');}
  });
}
function setUnreadNotificationCount(rows){unreadNotificationCount=rows.filter(item=>!item.read).length;updateNotificationBadge();}
async function refreshUnreadNotificationCount(){
  const token=++notificationFetchToken;
  if(!user){unreadNotificationCount=0;updateNotificationBadge();return;}
  try{const rows=await api('notifications');if(token===notificationFetchToken&&user)setUnreadNotificationCount(rows);}catch{/* Keep the current badge state if a refresh temporarily fails. */}
}
window.addEventListener('focus',()=>{if(user)void refreshUnreadNotificationCount();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&user)void refreshUnreadNotificationCount();});
const menuSections=()=>user?.role==='admin'
  ? [...ADMIN_MENU]
  : MENU.filter(name=>name!=='Города'&&name!=='Константы');

function renderMenu(section='Профиль'){
  openModal('Меню');
  if(user)void refreshUnreadNotificationCount();
  const sections=menuSections();if(!sections.includes(section))section='Профиль';
  activeMenuSection=section;
  const header=$('modal-title').parentElement;
  header.querySelector('.menu-mobile-picker')?.remove();
  const picker=document.createElement('select');picker.className='menu-mobile-picker';picker.setAttribute('aria-label','Раздел меню');
  picker.innerHTML=sections.map(name=>`<option value="${escape(name)}" ${name===section?'selected':''}>${escape(name)}</option>`).join('');
  picker.onchange=()=>renderMenu(picker.value);header.insertBefore(picker,$('close-modal'));
  const host=$('modal-content');
  host.innerHTML=`<div class="menu-layout"><nav class="menu-tabs" aria-label="Разделы сайта">${sections.map(name=>`<button type="button" data-section="${escape(name)}" class="${name===section?'active':''}">${escape(name)}</button>`).join('')}</nav><section id="menu-section" class="placeholder"></section></div>`;
  host.querySelectorAll('[data-section]').forEach(b=>b.onclick=()=>renderMenu(b.dataset.section));
  updateNotificationBadge();
  const content=$('menu-section');
  if(section==='Профиль')renderProfile(content);
  else if(section==='Государства'&&user?.role==='admin')renderStatesMenu(content);
  else if(section==='Уведомления'&&user)renderNotifications(content);
  else if(section==='Дипломатия'&&user?.role!=='admin')renderDynasticDiplomacy(content);
  else if(section==='Константы'&&user?.role==='admin')renderEconomyConstants(content);
  else if(section==='Экономика'&&user)renderEconomyMenu(content);
  else if(['Статистика','Власть и династия','Провинции','Производство','Торговля'].includes(section))renderPlayerStateSection(content,section);
  else content.innerHTML=`<span class="badge">ЗАПЛАНИРОВАНО</span><h3>${escape(section)}</h3><p class="hint">${section==='Сообщество VK'?'Ссылка на сообщество Fauxlore ещё не задана.':'Раздел оформлен как заготовка. Содержание и игровые правила требуют уточнения.'}</p>`;
  if($('profile-login'))$('profile-login').onclick=()=>renderAuth();
}

async function renderEconomyMenu(host){
  host.innerHTML='<h3>Экономика</h3><p class="hint">Загружаю показатели экономики…</p>';
  try{
    if(user?.role==='admin'){
      host.innerHTML='<h3>Экономика государства</h3><p class="hint">Откройте «Государства», выберите государство и перейдите во вкладку «Экономика».</p>';
    }else{
      const states=await api('my/states');if(!host.isConnected)return;
      if(!states.length){host.innerHTML='<h3>Экономика</h3><p class="hint">За вашим аккаунтом пока не закреплено государство. Администратор должен назначить вам государство.</p>';return;}
      const state=states.find(row=>user.state_ids?.includes(Number(row.id)))||states[0];
      host.innerHTML=`<div class="state-menu stack"><h3>Экономика · ${escape(state.name)}</h3><div data-state-economy><p class="hint">Загружаю баланс…</p></div></div>`;
      await renderStateEconomy(host,Number(state.id),false);
    }
  }catch(error){if(host.isConnected)host.innerHTML=`<h3>Экономика</h3><p class="form-message">${escape(error.message)}</p>`;}
}

async function loadTaxEditor(host,stateId,isAdmin){
  const saveButton=host.querySelector('[data-tax-save-all]');if(!saveButton||!stateId)return;
  const inputs=[...host.querySelectorAll('[data-tax-layer]')];
  saveButton.disabled=true;
  try{
    const data=await api(`${isAdmin?'admin':'my'}/states/${stateId}/tax-rates`);if(!saveButton.isConnected)return;
    for(const input of inputs){const group=data.groups.find(row=>row.layer===input.dataset.taxLayer&&Number(row.id)===Number(input.dataset.taxId));if(!group)continue;input.value=Number(group.rate);input.disabled=!isAdmin&&group.changed_this_turn;input.title=group.changed_this_turn?'Эту ставку уже меняли в текущем ходу':isAdmin?'Изменение бесплатно':'Стоимость изменения — 3 ОП';input.dataset.originalValue=String(Number(group.rate));}
    saveButton.disabled=false;
    saveButton.onclick=async()=>{
      const changed=inputs.filter(input=>!input.disabled&&Number(input.value)!==Number(input.dataset.originalValue));
      if(!changed.length){showStatus('Изменений налоговых ставок нет',3000);return;}
      if(!isAdmin&&Number(data.prestige)<changed.length*3){showStatus(`Для этих изменений нужно ${changed.length*3} ОП`,4000);return;}
      for(const input of changed){const value=Number(input.value);if(!Number.isFinite(value)||value<0||value>100){showStatus('Ставка должна быть от 0 до 100 G',4000);input.focus();return;}}
      saveButton.disabled=true;
      try{for(const input of changed)await api(`${isAdmin?'admin':'my'}/states/${stateId}/tax-rates`,{method:'POST',body:JSON.stringify({layer:input.dataset.taxLayer,category_id:Number(input.dataset.taxId),rate:Number(input.value)})});showStatus(isAdmin?'Ставки сохранены':'Ставки сохранены; списано 3 ОП за каждую изменённую группу',4500);await loadTaxEditor(host,stateId,isAdmin);}
      catch(error){saveButton.disabled=false;const message=host.querySelector('[data-tax-save-message]');if(message)message.textContent=error.message;showStatus(error.message,5000);}
    };
  }catch(error){saveButton.disabled=true;const message=host.querySelector('[data-tax-save-message]');if(message)message.textContent=error.message;}
}

async function renderStateEconomy(host,stateId,isAdmin,onRefresh=()=>{}){
  const target=host.querySelector('[data-state-economy]');if(!target)return;
  target.innerHTML='<p class="hint">Загружаю финансовые показатели…</p>';
  try{
    const [data,test,tradeData,stateList]=await Promise.all([api(`${isAdmin?'admin':'my'}/states/${stateId}/tax-rates`),isAdmin?api('admin/turn/test'):Promise.resolve(null),api('my/trade-agreements'),api(isAdmin?'admin/states':'my/states')]);
    if(!target.isConnected)return;
    const buckets=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
    const stateRecord=stateList.find(item=>Number(item.id)===Number(stateId)),stateName=stateRecord?.name||data.state_name;
    const rateByLayer=layer=>Object.fromEntries(data.groups.filter(group=>group.layer===layer).map(group=>[group.name,Number(group.rate)]));
    const stateRates={races:rateByLayer('races'),religions:rateByLayer('religions')};
    const forecastProvinces=allProvinces.filter(p=>Number(p.layers?.states?.id)===Number(stateId)||p.occupation===stateName).map(p=>{
      const ownerMatch=Number(p.layers?.states?.id)===Number(stateId),layers={...p.layers};
      if(ownerMatch)layers.states={...layers.states,race_tax_rates:stateRates.races,religion_tax_rates:stateRates.religions};
      return {...p,layers,...(!ownerMatch?{occupation_race_tax_rates:stateRates.races,occupation_religion_tax_rates:stateRates.religions}:{})};
    });
    const config=getEconomyConfig(),estateOrder=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
    const authorityStatus={'Династия':['Ключевое','Значимое','Значимое','Бесправное','Бесправное'],'Магистрат':['Бесправное','Значимое','Ключевое','Ключевое','Бесправное'],'Клир':['Значимое','Бесправное','Ключевое','Бесправное','Бесправное'],'Диктат':['Ключевое','Бесправное','Значимое','Бесправное','Бесправное'],'Вече':['Бесправное','Бесправное','Значимое','Значимое','Ключевое']};
    const economyStatus={'Крепостничество':['—','Ключевое','—','—','Бесправное'],'Гильдии':['—','—','—','Ключевое','—'],'Адмиралтейство':['Ключевое','—','—','Значимое','—'],'Корсарство':['—','—','—','Значимое','—'],'Работорговля':['—','—','—','—','Бесправное']};
    const taxForecast={total:0,buckets:Object.fromEntries(buckets.map(name=>[name,0]))};
    const roundMoney=value=>Math.round((value+Number.EPSILON)*100)/100;
    for(const province of forecastProvinces){
      const gross=calculateProvinceEconomy(province,stateName).taxes;if(gross===null)continue;
      taxForecast.total+=gross;const belonging=province.belonging||'Отсутствует',index=estateOrder.indexOf(belonging);
      if(index<0){taxForecast.buckets['Корона']+=gross;continue;}
      const principles=stateRecord?.principles||{},economic=economyStatus[principles.economy]?.[index],status=economic&&economic!=='—'?economic:(authorityStatus[principles.authority]?.[index]||'—');
      const greed=Number(config.estateTaxGreed?.[`${status}|${belonging}`]??0),crown=roundMoney(gross*(1-greed));
      taxForecast.buckets['Корона']+=crown;taxForecast.buckets[belonging]+=gross-crown;
    }
    taxForecast.total=roundMoney(taxForecast.total);for(const name of buckets)taxForecast.buckets[name]=roundMoney(taxForecast.buckets[name]);
    const agreements=(tradeData.agreements||[]).filter(item=>item.status==='accepted'&&(Number(item.from_state_id)===Number(stateId)||Number(item.to_state_id)===Number(stateId)));
    const tradeGoldIn=roundMoney(agreements.reduce((sum,item)=>sum+Number((Number(item.from_state_id)===Number(stateId)?item.terms?.to_gold:item.terms?.from_gold)||0),0));
    const tradeGoldOut=roundMoney(agreements.reduce((sum,item)=>sum+Number((Number(item.from_state_id)===Number(stateId)?item.terms?.from_gold:item.terms?.to_gold)||0),0));
    const upkeep=roundMoney(Number(data.army_upkeep_forecast)||0),debtRepayment=roundMoney(Math.min(Number(data.debt)||0,(Number(data.buckets?.Корона)||0)+taxForecast.buckets['Корона']+tradeGoldIn));
    const money=value=>`${roundMoney(value).toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})} G`,prestige=value=>`${roundMoney(value).toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})} ОП`;
    const testPanel=isAdmin?`<section class="application-panel"><h4>Проверка смены хода</h4><p class="hint">Тестовый ход запускает расчёты в игровой базе. Откат восстанавливает снимок, если после теста игровые данные не изменялись.</p><div class="inline-actions">${test.active?`<button type="button" class="danger-button" data-test-turn-rollback>Откатить тестовый ход (${Number(test.after_year)} / ${Number(test.after_turn)})</button>`:`<button type="button" data-test-turn-advance>Выполнить тестовый ход</button>`}</div><p class="hint">${test.active?`Можно вернуть календарь к ${Number(test.before_year)} году, ${Number(test.before_turn)} ходу.`:'После проверки откатите тестовый ход, чтобы восстановить игровые данные.'}</p></section>`:'';
    const sourceBlock=(title,rows,unit)=>`<section class="application-panel economy-source-card"><h4>${title}</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Источник</th><th>Прогноз</th></tr></thead><tbody>${rows.map(([name,value])=>`<tr><td>${name}</td><td>${unit(value)}</td></tr>`).join('')}</tbody></table></div></section>`;
    const sourceBlocks=`<h4>Прогноз на следующий ход</h4><p class="hint">Расчёт исходит из текущих провинций, ставок, состава армии и принятых договоров. Разовые операции показывают 0, если сейчас не ожидается соответствующее событие.</p><div class="economy-source-grid">${sourceBlock('Казна · постоянные доходы',[
      ['Налоги · все казны',taxForecast.total],['Налоги · Корона',taxForecast.buckets['Корона']],['Налоги · сословия',roundMoney(taxForecast.total-taxForecast.buckets['Корона'])],['Золото по торговым договорам',tradeGoldIn]
    ],money)}${sourceBlock('Казна · постоянные расходы',[
      ['Содержание армии',upkeep],['Платежи по торговым договорам',tradeGoldOut],['Погашение долга Короны',debtRepayment]
    ],money)}${sourceBlock('Казна · разовые доходы',[
      ['Другие разовые поступления',0]
    ],money)}${sourceBlock('Казна · разовые расходы',[
      ['Другие разовые списания',0]
    ],money)}${sourceBlock('Престиж · постоянные доходы и расходы',[
      ['Постоянные поступления',0],['Постоянные расходы',0]
    ],prestige)}${sourceBlock('Престиж · разовые доходы',[
      ['Династический брак (если будет принят)',0]
    ],prestige)}${sourceBlock('Престиж · разовые расходы',[
      ['Налоговые ставки, местный брак, торговые предложения и назначение наследника',0]
    ],prestige)}</div>`;
    target.innerHTML=`${testPanel}<div class="economy-balance-cards"><div><small>Казна Короны</small><strong>${Number(data.buckets?.Корона||0).toLocaleString('ru-RU')} G</strong></div><div><small>Долг Короны</small><strong>${Number(data.debt||0).toLocaleString('ru-RU')} G</strong></div><div><small>Престиж</small><strong>${Number(data.prestige||0).toLocaleString('ru-RU')} ОП</strong></div></div>${sourceBlocks}<section class="application-panel"><h4>Баланс средств сословий</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Баланс</th></tr></thead><tbody>${buckets.map(name=>`<tr><td>${name}</td><td>${Number(data.buckets?.[name]||0).toLocaleString('ru-RU')} G</td></tr>`).join('')}</tbody></table></div></section>`;
    if(isAdmin)bindTestTurn(host,test,onRefresh);
  }catch(error){if(target.isConnected)target.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

async function loadStateFinances(host,stateId,isAdmin){
  const target=host.querySelector('[data-state-finances]');if(!target)return;
  try{
    const data=await api(`${isAdmin?'admin':'my'}/states/${stateId}/tax-rates`);if(!target.isConnected)return;
    target.innerHTML=`<section class="state-dashboard-card"><h4>Казна Короны</h4><strong class="state-finance-total">${Number(data.buckets?.Корона||0).toLocaleString('ru-RU')} G</strong></section><section class="state-dashboard-card"><h4>Престиж</h4><strong class="state-finance-total">${Number(data.prestige||0).toLocaleString('ru-RU')} ОП</strong></section>`;
  }catch(error){if(target.isConnected)target.innerHTML=`<section class="state-dashboard-card"><h4>Казна и престиж</h4><p class="form-message">${escape(error.message)}</p></section>`;}
}

function bindTestTurn(host,test,onRefresh=()=>{}){
  const advance=host.querySelector('[data-test-turn-advance]');
  if(advance)advance.onclick=async()=>{advance.disabled=true;try{const cal=await api('game/calendar');const result=await api('admin/turn/test/advance',{method:'POST',body:JSON.stringify({expected_year:Number(cal.year),expected_turn:Number(cal.turn)})});renderCalendar(result);showStatus('Тестовый ход выполнен. Проверьте и нажмите «Откатить тестовый ход».',5000);await onRefresh();}catch(error){advance.disabled=false;showStatus(error.message,6000);}};
  const rollback=host.querySelector('[data-test-turn-rollback]');
  if(rollback)rollback.onclick=async()=>{rollback.disabled=true;try{const result=await api('admin/turn/test/rollback',{method:'POST',body:'{}'});renderCalendar(result);showStatus('Тестовый ход и его изменения полностью откатаны.',4500);await onRefresh();}catch(error){rollback.disabled=false;showStatus(error.message,6000);}};
}

async function renderDynasticDiplomacy(host,options={}){
  const stateId=Number(options.stateId)||null,isAdminState=user?.role==='admin'&&stateId!==null;
  host.innerHTML='<h3>Династические браки</h3><p class="hint">Загружаю дипломатические предложения…</p>';
  try{
    if(!await hasAuthenticatedSession()){
      if(host.isConnected)host.innerHTML='<h3>Династические браки</h3><p class="hint">Войдите через Google, чтобы открыть дипломатические предложения.</p>';
      return;
    }
    const data=await api('my/marriage-offers');
    if(!host.isConnected)return;
    const participantLabel=person=>`${person.name} ${person.surname||''} · ${person.age} лет · ${person.gender} · ${person.race}`.trim();
    const sendForm=!isAdminState&&data.states.length&&data.targets.length?`<form class="dynastic-offer-form stack"><label class="field"><span>От имени государства</span><select name="from_state" required>${data.states.map(state=>`<option value="${Number(state.id)}">${escape(state.name)} · ${escape(state.authority||'Форма власти не задана')}</option>`).join('')}</select></label><label class="field"><span>Государство-получатель</span><select name="to_state" required></select></label><label class="field"><span>Персонаж вашего государства</span><select name="from_character" required></select></label><label class="field"><span>Персонаж государства-получателя (противоположный пол)</span><select name="to_character" required></select></label><div class="marriage-warning" data-marriage-warning role="status">Выберите персонажей, чтобы увидеть последствия договора.</div><button class="primary" type="submit">Отправить предложение</button></form>`:'<p class="hint">Предложения династического брака создаются игроками государств.</p>';
    const proposalCard=(proposal,incoming)=>`<article class="application-panel marriage-candidate"><strong>${escape(proposal.from_state)} → ${escape(proposal.to_state)}</strong><span>${escape(proposal.from_ruler)} ↔ ${escape(proposal.to_ruler)}</span><p class="hint">Законность детей: ${proposal.lawful_for_children?'дети будут законными наследниками в государстве матери-Династии и войдут в её семейный реестр':'брак не даёт детям законного права на наследование'}. Зачатие: ${proposal.child_race&&Number(proposal.from_age)<(proposal.from_gender==='Мужской'?60:45)&&Number(proposal.to_age)<(proposal.to_gender==='Мужской'?60:45)?`возможно, раса ребёнка — ${escape(proposal.child_race)}`:'невозможно по возрасту или сочетаемости рас'}.</p><small>${new Date(proposal.created_at).toLocaleDateString('ru-RU')}</small>${incoming?`<div class="inline-actions"><button type="button" data-marriage-decision="accept" data-proposal-id="${Number(proposal.id)}">Принять</button><button type="button" class="danger-button" data-marriage-decision="reject" data-proposal-id="${Number(proposal.id)}">Отклонить</button></div>`:'<span class="hint">Ожидает ответа</span>'}</article>`;
    const relevant=item=>!stateId||Number(item.from_state_id)===stateId||Number(item.to_state_id)===stateId;
    const incoming=(data.incoming||[]).filter(relevant),outgoing=(data.outgoing||[]).filter(relevant);
    host.innerHTML=`<div class="state-menu stack"><h3>Дипломатия</h3><section class="application-panel"><h4>Предложить договор</h4><label class="field"><span>Тип договора</span><select data-contract-type><option value="dynastic_marriage" ${activeContractType==='dynastic_marriage'?'selected':''}>Династический брак</option><option value="trade" ${activeContractType==='trade'?'selected':''}>Торговый договор</option></select></label><div data-contract-panel="dynastic_marriage" ${activeContractType==='dynastic_marriage'?'':'hidden'}>${sendForm}</div><div data-contract-panel="trade" ${activeContractType==='trade'?'':'hidden'}><div data-trade-proposal><p class="hint">Загружаю торговые договоры…</p></div></div></section><section class="application-panel"><h4>Входящие предложения династического брака</h4>${incoming.length?`<div class="marriage-candidates">${incoming.map(item=>proposalCard(item,true)).join('')}</div>`:'<p class="hint">Входящих предложений нет.</p>'}</section><section class="application-panel"><h4>Отправленные предложения династического брака</h4>${outgoing.length?`<div class="marriage-candidates">${outgoing.map(item=>proposalCard(item,false)).join('')}</div>`:'<p class="hint">Ожидающих ответов нет.</p>'}</section></div>`;
    const tradeHost=host.querySelector('[data-trade-proposal]');
    void renderTradeProposal(tradeHost,{stateId});
    host.querySelector('[data-contract-type]')?.addEventListener('change',event=>{
      activeContractType=event.target.value;
      host.querySelectorAll('[data-contract-panel]').forEach(panel=>{panel.hidden=panel.dataset.contractPanel!==event.target.value;});
    });
    const form=host.querySelector('.dynastic-offer-form');
    if(form){
      const fromState=form.elements.from_state,toState=form.elements.to_state,fromCharacter=form.elements.from_character,toCharacter=form.elements.to_character,warning=form.querySelector('[data-marriage-warning]');
      const participants=data.participants||[];
      const fill=(select,items,placeholder)=>{select.innerHTML=`<option value="">${escape(placeholder)}</option>${items.map(item=>`<option value="${Number(item.id)}">${escape(participantLabel(item))}</option>`).join('')}`;};
      const refresh=()=>{
        const previousTarget=toState.value,previousSource=fromCharacter.value,previousTargetCharacter=toCharacter.value,sourceState=Number(fromState.value);
        const targets=data.targets.filter(state=>Number(state.id)!==sourceState);
        toState.innerHTML=targets.map(state=>`<option value="${Number(state.id)}">${escape(state.name)} · ${escape(state.authority||'Форма власти не задана')}</option>`).join('');
        if(targets.some(state=>Number(state.id)===Number(previousTarget)))toState.value=previousTarget;
        const sourcePeople=participants.filter(person=>Number(person.state_id)===sourceState);
        fill(fromCharacter,sourcePeople,'Выберите персонажа');
        const selectedSource=sourcePeople.find(person=>Number(person.id)===Number(previousSource))||sourcePeople[0];
        if(selectedSource)fromCharacter.value=String(selectedSource.id);
        const targetPeople=participants.filter(person=>Number(person.state_id)===Number(toState.value)&&(!selectedSource||person.gender!==selectedSource.gender));
        fill(toCharacter,targetPeople,targetPeople.length?'Выберите персонажа':'Нет доступных персонажей противоположного пола');
        const selectedTarget=targetPeople.find(person=>Number(person.id)===Number(previousTargetCharacter))||targetPeople[0];
        if(selectedTarget)toCharacter.value=String(selectedTarget.id);
        const source=sourcePeople.find(person=>Number(person.id)===Number(fromCharacter.value)),target=targetPeople.find(person=>Number(person.id)===Number(toCharacter.value));
        if(!source||!target){warning.textContent='Для выбранного сочетания нет доступной пары совершеннолетних персонажей без супруга.';return;}
        const lawful=data.states.find(state=>Number(state.id)===sourceState)?.authority==='Династия'&&targets.find(state=>Number(state.id)===Number(toState.value))?.authority==='Династия';
        const childRace=compatibleChildRace(source.race,target.race),male=source.gender==='Мужской'?source:target,female=source.gender==='Женский'?source:target;
        const canConceive=Boolean(childRace)&&Number(male.age)<60&&Number(female.age)<45;
        warning.textContent=`Законность детей: ${lawful?'дети будут законными наследниками в государстве матери-Династии; ребёнок вносится в её семейный реестр':'брак не даёт детям законного права на наследование'}. Зачатие: ${canConceive?`возможно; раса ребёнка — ${childRace}`:`невозможно${childRace?' из-за возраста персонажа':' из-за несовместимости рас'}`}. При принятии оба государства получат по 10 ОП.`;
      };
      const compatibleChildRace=(a,b)=>{
        if(a===b&&['Люди','Эльфы','Дварфы','Зверолюди'].includes(a))return a;
        if(['Люди','Эльфы','Полуэльфы'].includes(a)&&['Люди','Эльфы','Полуэльфы'].includes(b))return a==='Люди'&&b==='Люди'?'Люди':'Полуэльфы';
        return null;
      };
      fromState.addEventListener('change',refresh);toState.addEventListener('change',refresh);fromCharacter.addEventListener('change',refresh);refresh();
      form.addEventListener('submit',async event=>{event.preventDefault();const button=form.querySelector('[type="submit"]');if(!fromCharacter.value||!toCharacter.value){showStatus('Выберите допустимую пару персонажей',3500);return;}button.disabled=true;try{await api('my/marriage-offers',{method:'POST',body:JSON.stringify({from_state_id:Number(fromState.value),to_state_id:Number(toState.value),from_character_id:Number(fromCharacter.value),to_character_id:Number(toCharacter.value)})});showStatus('Предложение отправлено',3500);renderDynasticDiplomacy(host,options);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
    }
    host.querySelectorAll('[data-marriage-decision]').forEach(button=>button.addEventListener('click',async()=>{button.disabled=true;try{const prefix=user.role==='admin'?'admin':'my';await api(`${prefix}/marriage-offers/${Number(button.dataset.proposalId)}/${button.dataset.marriageDecision}`,{method:'POST',body:'{}'});showStatus(button.dataset.marriageDecision==='accept'?'Брак заключён; обе стороны получили по 10 ОП':'Предложение отклонено',4000);renderDynasticDiplomacy(host,options);}catch(error){button.disabled=false;showStatus(error.message,5000);}}));
  }catch(error){if(host.isConnected){host.innerHTML=`<div class="state-menu stack"><h3>Дипломатия</h3><section class="application-panel"><h4>Предложить договор</h4><label class="field"><span>Тип договора</span><select data-contract-type><option value="dynastic_marriage">Династический брак</option><option value="trade">Торговый договор</option></select></label><div data-contract-panel="dynastic_marriage"><p class="form-message">Предложения брака не загрузились: ${escape(error.message)}</p></div><div data-contract-panel="trade" hidden><div data-trade-proposal></div></div></section></div>`;void renderTradeProposal(host.querySelector('[data-trade-proposal]'));host.querySelector('[data-contract-type]')?.addEventListener('change',event=>{activeContractType=event.target.value;host.querySelectorAll('[data-contract-panel]').forEach(panel=>{panel.hidden=panel.dataset.contractPanel!==event.target.value;});});}}
}

function tradeTermsText(goods,gold){
  const parts=(goods||[]).map(item=>`${escape(item.name)} — ${Number(item.quantity).toLocaleString('ru-RU')}`);
  if(Number(gold)>0)parts.push(`${Number(gold).toLocaleString('ru-RU')} G`);
  return parts.length?parts.join(', '):'ничего';
}
function tradeAvailable(data,stateId,name){return Number(tradeAvailability[Number(stateId)]?.find(row=>row.name===name)?.available||0);}
async function loadTradeAvailability(stateId){
  const key=Number(stateId);if(!key)return [];
  if(Object.prototype.hasOwnProperty.call(tradeAvailability,key))return tradeAvailability[key];
  const result=await api(`my/trade-availability/${key}`);tradeAvailability[key]=result.resources||[];return tradeAvailability[key];
}
function tradeRouteNames(ids){return ids.map(id=>{const p=allProvinces.find(row=>Number(row.id)===Number(id));return `${escape(p?.name||'Провинция')} · ID ${Number(id)}`;}).join(' → ');}
function syncTradeDraft(form){
  tradeProposalDraft.fromStateId=Number(form.elements.from_state.value)||null;tradeProposalDraft.toStateId=Number(form.elements.to_state.value)||null;
  tradeProposalDraft.fromGold=Number(form.elements.from_gold.value)||0;tradeProposalDraft.toGold=Number(form.elements.to_gold.value)||0;
  for(const side of ['from','to'])tradeProposalDraft[`${side}Goods`]=[...form.querySelectorAll(`[data-trade-side="${side}"] .trade-good-row`)].map(row=>({name:row.querySelector('select').value,quantity:Number(row.querySelector('input').value)||0}));
}
function tradeGoodRows(resources,side,stateId,rows){
  return `<div class="trade-goods-list" data-trade-side="${side}">${rows.map((row,index)=>`<div class="trade-good-row"><select aria-label="Ресурс ${index+1}"><option value="">Выберите ресурс</option>${resources.map(r=>`<option value="${escape(r.name)}" ${r.name===row.name?'selected':''}>${escape(r.name)}</option>`).join('')}</select><input type="number" min="0.01" step="0.01" value="${Number(row.quantity)||''}" placeholder="Количество" aria-label="Количество ресурса ${index+1}"><small data-available-note>${row.name?`Доступно: ${tradeAvailable(null,stateId,row.name).toLocaleString('ru-RU')}`:'Выберите ресурс'}</small>${rows.length>1?`<button type="button" data-trade-remove aria-label="Удалить строку">×</button>`:''}</div>`).join('')}<button type="button" class="trade-add-resource" data-trade-add="${side}" aria-label="Добавить ресурс">+</button></div>`;
}
async function renderTradeProposal(host,options={}){
  const stateId=Number(options.stateId)||null;
  if(!host)return;host.innerHTML='<section class="application-panel"><h4>Торговые договоры</h4><p class="hint">Загружаю доступные товары и предложения…</p></section>';
  try{
    if(!await hasAuthenticatedSession()){if(host.isConnected)host.innerHTML='<section class="application-panel"><h4>Торговые договоры</h4><p class="hint">Войдите, чтобы предложить договор.</p></section>';return;}
    const data=await api('my/trade-agreements');if(!host.isConnected)return;
    const allOwn=(data.states||[]),own=stateId&&user.role==='admin'?allOwn.filter(s=>Number(s.id)===stateId):allOwn,targets=(data.targets||[]);
    if(stateId&&user.role==='admin')tradeProposalDraft.fromStateId=stateId;
    if(!tradeProposalDraft.fromStateId||!own.some(s=>Number(s.id)===Number(tradeProposalDraft.fromStateId)))tradeProposalDraft.fromStateId=Number(own[0]?.id)||null;
    const eligible=targets.filter(s=>Number(s.id)!==Number(tradeProposalDraft.fromStateId)&&(user.role==='admin'||!own.some(x=>Number(x.id)===Number(s.id))));
    if(!tradeProposalDraft.toStateId||!eligible.some(s=>Number(s.id)===Number(tradeProposalDraft.toStateId)))tradeProposalDraft.toStateId=Number(eligible[0]?.id)||null;
    if(!tradeProposalDraft.route.length)tradeProposalDraft.route=[];
    const route=tradeProposalDraft.route.length?`<p class="trade-route-preview">${tradeRouteNames(tradeProposalDraft.route)}</p>`:'<p class="hint" data-trade-route-placeholder>Маршрут ещё не выбран.</p>';
    const form=own.length&&eligible.length?`<form class="application-panel trade-agreement-form stack"><h4>Предложить торговый договор</h4><div class="editor-grid"><label class="field"><span>От имени государства</span><select name="from_state" required>${own.map(s=>`<option value="${Number(s.id)}" ${Number(s.id)===Number(tradeProposalDraft.fromStateId)?'selected':''}>${escape(s.name)}</option>`).join('')}</select></label><label class="field"><span>Государство-получатель</span><select name="to_state" required>${eligible.map(s=>`<option value="${Number(s.id)}" ${Number(s.id)===Number(tradeProposalDraft.toStateId)?'selected':''}>${escape(s.name)}</option>`).join('')}</select></label></div><div class="trade-route-controls"><button type="button" data-trade-pick-route>Выбрать маршрут на карте</button><span data-trade-route-status>${tradeRoutePick?'Выберите начальный город на карте':tradeProposalDraft.route.length?'Маршрут выбран':'Выберите города и промежуточные провинции кликами на карте.'}</span>${route}</div><div class="trade-offer-grid"><section class="trade-offer-side"><h4>Ресурсы от вашего государства</h4>${tradeGoodRows(data.resources||[],'from',tradeProposalDraft.fromStateId,tradeProposalDraft.fromGoods)}</section><section class="trade-offer-side"><h4>Ресурсы от получателя</h4>${tradeGoodRows(data.resources||[],'to',tradeProposalDraft.toStateId,tradeProposalDraft.toGoods)}</section><label class="field"><span>G от вашего государства</span><input name="from_gold" type="number" min="0" step="0.01" value="${Number(tradeProposalDraft.fromGold)||0}"></label><label class="field"><span>G от получателя</span><input name="to_gold" type="number" min="0" step="0.01" value="${Number(tradeProposalDraft.toGold)||0}"></label></div><button class="primary" type="submit">Отправить предложение · 3 ОП</button></form>`:'<p class="hint">Для предложения нужны закреплённое за вами государство и другое государство-получатель.</p>';
    const agreements=(data.agreements||[]).filter(item=>!stateId||Number(item.from_state_id)===stateId||Number(item.to_state_id)===stateId);
    const cards=agreements.map(item=>`<article class="application-panel marriage-candidate"><strong>${escape(item.from_state)} → ${escape(item.to_state)}</strong><span>${escape(item.status==='pending'?'Ожидает ответа':item.status==='accepted'?'Исполняется каждый ход':item.status)}</span><p>Маршрут: ${tradeRouteNames(item.route_province_ids||[])}</p><p>Отправитель: ${tradeTermsText(item.terms?.from_goods,item.terms?.from_gold)}</p><p>Получатель: ${tradeTermsText(item.terms?.to_goods,item.terms?.to_gold)}</p><small>${Number(item.created_year)} год · ${Number(item.created_turn)} ход</small>${item.status==='pending'&&item.incoming?`<div class="inline-actions"><button type="button" data-trade-action="accept" data-trade-id="${Number(item.id)}">Принять</button><button type="button" class="danger-button" data-trade-action="decline" data-trade-id="${Number(item.id)}">Отклонить</button></div>`:''}${['pending','accepted'].includes(item.status)&&(!item.incoming||user.role==='admin')?`<div class="inline-actions"><button type="button" class="danger-button" data-trade-action="cancel" data-trade-id="${Number(item.id)}">Расторгнуть / отозвать</button></div>`:''}</article>`).join('');
    host.innerHTML=`${form}<section class="application-panel"><h4>Предложения торговых договоров</h4>${cards||'<p class="hint">Предложений пока нет.</p>'}</section>`;
    const tradeForm=host.querySelector('.trade-agreement-form');if(!tradeForm)return;
    const refreshAvailability=async side=>{const stateId=Number(tradeForm.elements[side==='from'?'from_state':'to_state'].value);try{await loadTradeAvailability(stateId);}catch(error){showStatus(error.message,5000);}if(!tradeForm.isConnected)return;for(const row of tradeForm.querySelectorAll(`[data-trade-side="${side}"] .trade-good-row`)){const name=row.querySelector('select').value,note=row.querySelector('[data-available-note]'),input=row.querySelector('input');const qty=name?tradeAvailable(data,stateId,name):0;note.textContent=name?`Доступно: ${qty.toLocaleString('ru-RU')}`:'Выберите ресурс';input.max=String(qty);}};
    tradeForm.addEventListener('change',event=>{if(event.target.name==='from_state'||event.target.name==='to_state'){tradeProposalDraft.route=[];window.dispatchEvent(new CustomEvent('trade:route-pick',{detail:{active:false,clear:true}}));tradeForm.querySelector('.trade-route-preview')?.remove();const placeholder=tradeForm.querySelector('[data-trade-route-placeholder]');if(!placeholder){const note=document.createElement('p');note.className='hint';note.dataset.tradeRoutePlaceholder='';note.textContent='Маршрут ещё не выбран.';tradeForm.querySelector('.trade-route-controls')?.append(note);}const status=tradeForm.querySelector('[data-trade-route-status]');if(status)status.textContent='Выберите города и промежуточные провинции кликами на карте.';void refreshAvailability(event.target.name==='from_state'?'from':'to');}else if(event.target.matches('.trade-good-row select')){const row=event.target.closest('.trade-good-row'),name=event.target.value,side=row.closest('.trade-goods-list').dataset.tradeSide,stateId=Number(tradeForm.elements[side==='from'?'from_state':'to_state'].value);const duplicates=[...row.closest('.trade-goods-list').querySelectorAll('.trade-good-row select')].filter(select=>select.value===name);if(name&&duplicates.length>1){event.target.value='';showStatus('Каждый ресурс можно добавить только один раз на сторону договора.',3500);}const selectedName=event.target.value;row.querySelector('[data-available-note]').textContent=selectedName?`Доступно: ${tradeAvailable(data,stateId,selectedName).toLocaleString('ru-RU')}`:'Выберите ресурс';row.querySelector('input').max=String(tradeAvailable(data,stateId,selectedName));}syncTradeDraft(tradeForm);});
    tradeForm.addEventListener('input',()=>syncTradeDraft(tradeForm));
    tradeForm.querySelectorAll('[data-trade-add]').forEach(button=>button.onclick=()=>{syncTradeDraft(tradeForm);tradeProposalDraft[`${button.dataset.tradeAdd}Goods`].push({name:'',quantity:0});void renderTradeProposal(host,options);});
    tradeForm.querySelectorAll('[data-trade-remove]').forEach(button=>button.onclick=()=>{const side=button.closest('.trade-goods-list').dataset.tradeSide;syncTradeDraft(tradeForm);tradeProposalDraft[`${side}Goods`].splice([...button.closest('.trade-goods-list').querySelectorAll('.trade-good-row')].indexOf(button.closest('.trade-good-row')),1);void renderTradeProposal(host,options);});
    void refreshAvailability('from');void refreshAvailability('to');
    tradeForm.querySelector('[data-trade-pick-route]').onclick=()=>{syncTradeDraft(tradeForm);tradeProposalDraft.route=[];activeContractType='trade';tradeRoutePick={fromStateId:Number(tradeForm.elements.from_state.value),toStateId:Number(tradeForm.elements.to_state.value),adminStateId:stateId,ids:[]};$('modal')?.close();window.dispatchEvent(new CustomEvent('trade:route-pick',{detail:{active:true}}));showStatus('Выберите на карте начальный город, маршрут по соседним провинциям и город получателя. Esc — отмена.',0);};
    tradeForm.addEventListener('submit',async event=>{event.preventDefault();syncTradeDraft(tradeForm);const button=tradeForm.querySelector('[type="submit"]');try{
      const route=tradeProposalDraft.route.map(Number);if(route.length<2)throw new Error('Сначала выберите маршрут на карте');
      await Promise.all([loadTradeAvailability(tradeProposalDraft.fromStateId),loadTradeAvailability(tradeProposalDraft.toStateId)]);
      const cleanGoods=side=>tradeProposalDraft[`${side}Goods`].filter(row=>row.name&&Number(row.quantity)>0).map(row=>({name:row.name,quantity:Number(row.quantity)}));
      const fromGoods=cleanGoods('from'),toGoods=cleanGoods('to');
      for(const [side,goods] of [['from',fromGoods],['to',toGoods]])for(const item of goods){const stateId=Number(tradeForm.elements[side==='from'?'from_state':'to_state'].value);if(item.quantity>tradeAvailable(data,stateId,item.name))throw new Error(`Доступно только ${tradeAvailable(data,stateId,item.name).toLocaleString('ru-RU')} ресурса «${item.name}»`);}
      const payload={from_state_id:Number(tradeForm.elements.from_state.value),to_state_id:Number(tradeForm.elements.to_state.value),from_city_province_id:route[0],to_city_province_id:route.at(-1),route_province_ids:route,from_goods:fromGoods,to_goods:toGoods,from_gold:Number(tradeForm.elements.from_gold.value||0),to_gold:Number(tradeForm.elements.to_gold.value||0)};
      button.disabled=true;await api('my/trade-agreements',{method:'POST',body:JSON.stringify(payload)});tradeProposalDraft={fromStateId:payload.from_state_id,toStateId:null,route:[],fromGoods:[{name:'',quantity:0}],toGoods:[{name:'',quantity:0}],fromGold:0,toGold:0};window.dispatchEvent(new CustomEvent('trade:route-pick',{detail:{active:false,clear:true}}));showStatus(user.role==='admin'?'Предложение создано':'Предложение отправлено; списано 3 ОП',4000);void renderTradeProposal(host,options);
    }catch(error){button.disabled=false;showStatus(error.message,5000);}});
    host.querySelectorAll('[data-trade-action]').forEach(button=>button.addEventListener('click',async()=>{button.disabled=true;try{const prefix=user.role==='admin'?'admin':'my';const result=await api(`${prefix}/trade-agreements/${Number(button.dataset.tradeId)}/${button.dataset.tradeAction}`,{method:'POST',body:'{}'});showStatus(result.status==='accepted'?'Договор согласован':'Статус договора обновлён',4000);void renderTradeProposal(host,options);}catch(error){button.disabled=false;showStatus(error.message,5000);}}));
  }catch(error){if(host.isConnected)host.innerHTML=`<section class="application-panel"><h4>Торговые договоры</h4><p class="form-message">${escape(error.message)}</p></section>`;}
}
window.addEventListener('trade:route-province-picked',event=>{
  const province=event.detail;if(!tradeRoutePick||!province)return;const id=Number(province.id),first=tradeRoutePick.ids.length===0,last=tradeRoutePick.ids.at(-1);
  const stateId=Number(province.layers?.states?.id),isCity=province.kind==='land'&&(province.has_capital_marker||province.has_city_marker||mapMarkers.some(marker=>Number(marker.province_id)===id&&['capital','city'].includes(marker.type)));
  if(first){if(!isCity||stateId!==tradeRoutePick.fromStateId){showStatus('Начните маршрут с города или столицы своего государства.',3500);return;}tradeRoutePick.ids.push(id);showStatus(`Начало маршрута: ${province.name||id}. Выбирайте соседние провинции или город получателя.`,0);window.dispatchEvent(new CustomEvent('trade:route-progress',{detail:{ids:[...tradeRoutePick.ids]}}));return;}
  if(tradeRoutePick.ids.includes(id)){showStatus('Нельзя повторно включать провинцию в маршрут.',3000);return;}
  if(!(provinceAdjacency[last]||[]).some(value=>Number(value)===id)){showStatus('Следующая провинция должна быть соседней. Выберите промежуточную провинцию.',3500);return;}
  if(tradeRoutePick.ids.length>=10){showStatus('Маршрут ограничен 10 провинциями.',3500);return;}
  tradeRoutePick.ids.push(id);window.dispatchEvent(new CustomEvent('trade:route-progress',{detail:{ids:[...tradeRoutePick.ids]}}));
  if(isCity&&stateId===tradeRoutePick.toStateId){const context=tradeRoutePick;tradeProposalDraft.route=[...context.ids];tradeProposalDraft.fromStateId=context.fromStateId;tradeProposalDraft.toStateId=context.toStateId;tradeRoutePick=null;window.dispatchEvent(new CustomEvent('trade:route-pick',{detail:{active:false}}));showStatus('Маршрут выбран.',3000);if(context.adminStateId){pendingStateNavigation={stateId:context.adminStateId,tab:'Дипломатия'};renderMenu('Государства');}else renderMenu('Дипломатия');return;}
  showStatus(`Провинция добавлена (${tradeRoutePick.ids.length}/10). Выберите следующую соседнюю провинцию.`,0);
});
window.addEventListener('trade:route-cancelled',()=>{if(!tradeRoutePick)return;const context=tradeRoutePick;tradeRoutePick=null;window.dispatchEvent(new CustomEvent('trade:route-pick',{detail:{active:false,clear:true}}));showStatus('Выбор маршрута отменён.',2500);if(context.adminStateId){pendingStateNavigation={stateId:context.adminStateId,tab:'Дипломатия'};renderMenu('Государства');}else renderMenu('Дипломатия');});
async function renderTradeAgreements(host,stateId){
  host.innerHTML='<p class="hint">Загружаю данные торговли…</p>';
  try{
    const statePrefix=user?.role==='admin'?'admin':'my';
    const [data,settlements,market,interzone,duty]=await Promise.all([api('my/trade-agreements'),api('my/trade-settlements'),api('my/trade-market'),api('my/trade-interzone'),api(`${statePrefix}/states/${Number(stateId)}/trade-duty`)]);if(!host.isConnected)return;
    const relates=item=>Number(item.from_state_id)===Number(stateId)||Number(item.to_state_id)===Number(stateId);
    const agreements=(data.agreements||[]).filter(relates),settlementRows=(settlements.lines||[]).filter(line=>Number(line.sender_state_id)===Number(stateId)||Number(line.recipient_state_id)===Number(stateId)||(line.transit_fees||[]).some(fee=>Number(fee.state_id)===Number(stateId))).map(line=>{const fees=(line.transit_fees||[]).map(fee=>`${escape(fee.state_name)} · ${Number(fee.amount||0).toLocaleString('ru-RU')} G`).join('<br>')||'—';return `<tr><td>${Number(line.year)} · ${Number(line.turn)}</td><td>${escape(line.sender)} → ${escape(line.recipient)}</td><td>${line.item_kind==='gold'?'G':escape(line.item_name)}</td><td>${Number(line.sent).toLocaleString('ru-RU')}</td><td>${Number(line.received).toLocaleString('ru-RU')}</td><td>${Number(line.lost).toLocaleString('ru-RU')}</td><td>${fees}</td></tr>`;}).join('');
    const marketRows=(market.lines||[]).filter(line=>Number(line.buyer_state_id)===Number(stateId)||Number(line.seller_state_id)===Number(stateId)).map(line=>`<tr><td>${Number(line.year)} · ${Number(line.turn)}</td><td>${escape(line.zone)}</td><td>${escape(line.resource_name)}</td><td>${escape(line.seller)} → ${escape(line.buyer)}</td><td>${Number(line.quantity).toLocaleString('ru-RU')}</td><td>${Number(line.internal_duty_amount||0).toLocaleString('ru-RU')} G</td><td>${Number(line.buyer_influence||0).toLocaleString('ru-RU')}</td></tr>`).join('');
    const interzoneRows=(interzone.lines||[]).filter(line=>Number(line.buyer_state_id)===Number(stateId)||Number(line.seller_state_id)===Number(stateId)).map(line=>`<tr><td>${Number(line.year)} · ${Number(line.turn)}</td><td>${escape(line.from_zone)} → ${escape(line.to_zone)}</td><td>${escape(line.resource_name)}</td><td>${escape(line.seller)} → ${escape(line.buyer)}</td><td>${Number(line.distance)} пров.</td><td>${Number(line.quantity).toLocaleString('ru-RU')}</td><td>${Number(line.buyer_influence||0).toLocaleString('ru-RU')}</td></tr>`).join('');
    const cards=agreements.map(item=>`<article class="application-panel marriage-candidate"><strong>${escape(item.from_state)} → ${escape(item.to_state)}</strong><span>${escape(item.status==='pending'?'Ожидает ответа':item.status==='accepted'?'Исполняется каждый ход':item.status)}</span><p>Маршрут: ${tradeRouteNames(item.route_province_ids||[])}</p><p>Отправитель: ${tradeTermsText(item.terms?.from_goods,item.terms?.from_gold)}</p><p>Получатель: ${tradeTermsText(item.terms?.to_goods,item.terms?.to_gold)}</p></article>`).join('');
    const loyaltyEffect=Number(duty.loyalty_change_pp||0),dutyForm=`<form class="application-panel trade-duty-form"><h4>Внутренняя пошлина</h4><label class="field"><span>Ставка государства · ${Number(duty.cost)} ОП за изменение</span><input name="rate" type="number" min="0" max="30" step="0.5" value="${Number(duty.rate)}" ${duty.changed_this_turn?'disabled':''}></label><p class="hint">Базовая ставка — 15%. Доход от сбора получает Корона государства-покупателя. За каждый ход ставка выше базы снижает лояльность горожан на 0,25 п.п. за каждый процентный пункт ставки; ниже базы — повышает. Сейчас изменение: ${loyaltyEffect>0?'+':''}${loyaltyEffect.toLocaleString('ru-RU')} п.п./ход. ${duty.changed_this_turn?'В этом ходу ставку уже меняли.':''}</p><button type="submit" ${duty.changed_this_turn?'disabled':''}>Изменить ставку</button></form>`;
    host.innerHTML=`<div class="trade-top-cards"><div class="trade-distance-card"><small>Торговая дистанция</small><strong>10 провинций</strong><span>Максимальная длина договорного маршрута, включая начальный и конечный города.</span></div>${dutyForm}</div><p class="hint">Торговые договоры, поставки по ним и распределение товаров в торговых зонах для этого государства.</p><section class="application-panel"><h4>Договоры</h4>${cards||'<p class="hint">Торговых договоров пока нет.</p>'}</section><section class="application-panel"><h4>Поставки по договорам</h4>${settlementRows?`<div class="table-scroll"><table><thead><tr><th>Ход</th><th>Стороны</th><th>Ресурс / G</th><th>Отправлено</th><th>Получено</th><th>Потери</th><th>Пошлины третьих стран</th></tr></thead><tbody>${settlementRows}</tbody></table></div>`:'<p class="hint">Поставок пока нет.</p>'}</section><section class="application-panel"><h4>Рынок торговой зоны</h4>${marketRows?`<div class="table-scroll"><table><thead><tr><th>Ход</th><th>Зона</th><th>Ресурс</th><th>Источник → получатель</th><th>Количество</th><th>Пошлина покупателя</th><th>Влияние получателя</th></tr></thead><tbody>${marketRows}</tbody></table></div>`:'<p class="hint">Расчёт рынка выполняется при смене хода. Пока нет записей завершённых торговых расчётов.</p>'}</section><section class="application-panel"><h4>Поставки между торговыми зонами</h4>${interzoneRows?`<div class="table-scroll"><table><thead><tr><th>Ход</th><th>Маршрут зон</th><th>Ресурс</th><th>Источник → получатель</th><th>Путь</th><th>Количество</th><th>Влияние получателя</th></tr></thead><tbody>${interzoneRows}</tbody></table></div>`:'<p class="hint">Межзонных поставок пока нет.</p>'}</section>`;
    const dutyFormNode=host.querySelector('.trade-duty-form');dutyFormNode?.addEventListener('submit',async event=>{event.preventDefault();const button=dutyFormNode.querySelector('[type="submit"]');button.disabled=true;try{const rate=Number(dutyFormNode.elements.rate.value);const result=await api(`${statePrefix}/states/${Number(stateId)}/trade-duty`,{method:'POST',body:JSON.stringify({rate})});showStatus(result.unchanged?'Ставка не изменилась':`Ставка обновлена${result.cost?` · списано ${result.cost} ОП`:''}`,4000);void renderTradeAgreements(host,stateId);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
  }catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

function renderPlayerStateSection(host,tab,quiet=false){
  if(!user){host.innerHTML='<h3>Государство</h3><p class="hint">Войдите, чтобы открыть государственные данные.</p>';return;}
  if(!quiet)host.innerHTML='<p class="hint">Загружаю государство…</p>';
  api('my/states').then(async states=>{
    if(!host.isConnected)return;
    if(!states.length){host.innerHTML='<h3>Государство</h3><p class="hint">За вашим аккаунтом пока не закреплено государство. Администратор должен назначить его игроку.</p>';return;}
    const chosen=states.find(state=>user.state_ids?.includes(Number(state.id)))||states[0];
    const stateCategory=categories.find(category=>category.layer==='states'&&category.id===Number(chosen.id));
    const crime=Number(chosen.crime??stateCategory?.crime??.2);
    const provinces=(chosen.provinces||[]).map(p=>({...p,layers:{states:{id:Number(chosen.id),name:chosen.name,crime},races:p.race?{name:p.race}:null,religions:p.religion?{name:p.religion}:null,resources:p.resource?{name:p.resource}:null}}));
    provinces.push(...allProvinces.filter(p=>p.kind==='land'&&p.occupation===chosen.name&&!provinces.some(owned=>owned.id===p.id)));
    try{
      const rates=await api(`my/states/${Number(chosen.id)}/tax-rates`);
      chosen.tax_rates={races:Object.fromEntries(rates.groups.filter(row=>row.layer==='races').map(row=>[row.name,Number(row.rate)])),religions:Object.fromEntries(rates.groups.filter(row=>row.layer==='religions').map(row=>[row.name,Number(row.rate)]))};
      provinces.forEach(province=>{if(Number(province.layers?.states?.id)===Number(chosen.id)){province.layers.states.race_tax_rates=chosen.tax_rates.races;province.layers.states.religion_tax_rates=chosen.tax_rates.religions;}});
    }catch{/* Other player sections remain available if tax data is temporarily unavailable. */}
    renderStateDetails(host,{...chosen,crime},tab,provinces,false);
  }).catch(error=>{if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;});
}

function renderStateDetails(host,state,tab,provinces,isAdmin){
  const ownedProvinces=provinces.filter(p=>Number(p.layers?.states?.id)===Number(state.id));
  const population=ownedProvinces.reduce((sum,p)=>sum+Number(p.population||0),0);
  const provinceEconomy=provinces.map(p=>calculateProvinceEconomy(p,state.name));
  const unresolvedTaxes=provinceEconomy.filter(item=>item.taxes===null).length;
  const productionRows=calculateStateProduction(provinces,state.name);
  const crime=Number(state.crime??provinces.find(p=>p.layers?.states?.crime!=null)?.layers.states.crime??.2);
  const groupStats=(layer,official)=>{
    const groups=new Map();
    for(const province of ownedProvinces){
      const name=province.layers?.[layer]?.name;
      if(!name)continue;
      if(!groups.has(name))groups.set(name,{name,population:0,provinceCount:0});
      const item=groups.get(name);
      item.population+=Number(province.population)||0;item.provinceCount++;
    }
    const total=[...groups.values()].reduce((sum,item)=>sum+item.population,0);
    return [...groups.values()].sort((a,b)=>b.population-a.population||a.name.localeCompare(b.name,'ru')).map(item=>({...item,
      status:item.name===official?'Официальная':'—',share:total?item.population/total:0}));
  };
  const allEstateStats=['Корона','Знать','Духовенство','Горожане','Крестьяне'].map(name=>{
    const members=ownedProvinces.filter(province=>province.belonging===name);
    const values=provinces.filter(province=>province.belonging===name&&(province.layers?.states?.name===state.name||province.occupation===state.name)).map(province=>calculateProvinceValue(province,state.name));
    return {name,provinceCount:members.length,population:members.reduce((sum,province)=>sum+(Number(province.population)||0),0),
      weight:values.some(value=>value===null)?null:values.reduce((sum,value)=>sum+value,0)};
  });
  const estateStats=allEstateStats.filter(item=>item.provinceCount>0||item.weight>0);
  const totalEstateWeight=allEstateStats.every(item=>item.weight!==null)?allEstateStats.reduce((sum,item)=>sum+item.weight,0):null;
  const pct=value=>`${(value*100).toLocaleString('ru-RU',{minimumFractionDigits:1,maximumFractionDigits:1})}%`;
  const groupTable=(title,rows,groupType)=>`<h4>${title}</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Название</th><th>Статус</th><th>Население</th><th>Доля</th><th>Лояльность</th><th>Стабилизация</th><th>Налоговая ставка, G</th></tr></thead><tbody>${rows.length?rows.map(row=>{const layer=groupType==='race'?'races':'religions',key=categories.find(c=>c.layer===layer&&c.name===row.name)?.id;return `<tr><td>${escape(row.name)}</td><td data-politics-status="${groupType}:${key}">${row.status}</td><td>${row.population.toLocaleString('ru-RU')}</td><td>${pct(row.share)}</td><td data-politics-loyalty="${groupType}:${key}">50%</td><td data-politics-stability="${groupType}:${key}">—</td><td><input class="tax-rate-inline" type="number" min="0" max="100" step="0.01" value="" disabled data-tax-layer="${layer}" data-tax-id="${Number(key)}" aria-label="Ставка налога для ${escape(row.name)}"></td></tr>`}).join(''):`<tr><td colspan="7" class="hint">Нет назначенных значений.</td></tr>`}</tbody></table></div>`;
  const principles=state.principles||{};
  const principleLabels={authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина',ephemeral:'Эфемерный принцип'};
  const estateStatuses={
    authority:{
      'Династия':['Ключевое','Значимое','Значимое','Бесправное','Бесправное'],
      'Магистрат':['Бесправное','Значимое','Ключевое','Ключевое','Бесправное'],
      'Клир':['Значимое','Бесправное','Ключевое','Бесправное','Бесправное'],
      'Диктат':['Ключевое','Бесправное','Значимое','Бесправное','Бесправное'],
      'Вече':['Бесправное','Бесправное','Значимое','Значимое','Ключевое'],
    },
    economy:{
      'Крепостничество':['—','Ключевое','—','—','Бесправное'],
      'Гильдии':['—','—','—','Ключевое','—'],
      'Адмиралтейство':['Ключевое','—','—','Значимое','—'],
      'Корсарство':['—','—','—','Значимое','—'],
      'Работорговля':['—','—','—','—','Бесправное'],
    },
  };
  const estateOrder=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
  const estateStatus=name=>{
    const index=estateOrder.indexOf(name);
    const economic=estateStatuses.economy[principles.economy]?.[index];
    return economic&&economic!=='—'?economic:(estateStatuses.authority[principles.authority]?.[index]||'—');
  };
  let detail='';
  if(tab==='Статистика'){
    const totalDevelopment=ownedProvinces.some(province=>province.development!==null&&province.development!==undefined)
      ?ownedProvinces.reduce((sum,province)=>sum+(Number(province.development)||0),0):null;
    const urbanPopulation=ownedProvinces.reduce((sum,province)=>sum+Number(province.population||0)*({Столичная:.35,Городская:.2}[province.province_type]||0),0);
    const ruralPopulation=population-urbanPopulation;
    const estatesTable=estateStats.length
      ?`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Статус</th><th>Население</th><th>Вес</th><th>Влияние</th><th>Лояльность</th><th>Стабилизация</th></tr></thead><tbody>${estateStats.map(item=>`<tr><td>${escape(item.name)}</td><td data-politics-status="estate:${escape(item.name)}">${estateStatus(item.name)}</td><td>${item.population.toLocaleString('ru-RU')}</td><td>${item.weight===null?'—':item.weight.toLocaleString('ru-RU')}</td><td data-estate-influence="${escape(item.name)}">${totalEstateWeight&&item.weight!==null?pct(item.weight/totalEstateWeight):'—'}</td><td data-politics-loyalty="estate:${escape(item.name)}">50%</td><td data-politics-stability="estate:${escape(item.name)}">—</td></tr>`).join('')}</tbody></table></div>`
      :'<div class="table-scroll"><table class="state-data-table"><tbody><tr><td class="hint">В провинциях не назначены сословия.</td></tr></tbody></table></div>';
    const advisors=[['Административный','Казначей'],['Глашатай','Купец'],['Стратег','Штабист']];
    const advisorsTable=`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Советник</th><th>Имя советника</th><th>Уровень</th><th>Тип советника</th><th>Бонус</th><th>Содержание ОП/ход</th></tr></thead><tbody>${advisors.map(([type,specialty])=>`<tr><td>${type}</td><td>—</td><td>1</td><td>${specialty}</td><td>—</td><td>1</td></tr>`).join('')}</tbody></table></div>`;
    detail=`<div class="state-identity"><div class="state-emblem-frame"><div class="state-emblem-placeholder" data-emblem-placeholder>Символика<br>не загружена</div><img class="state-emblem-image" data-state-emblem alt="Символика государства" hidden>${isAdmin?`<button type="button" class="state-emblem-edit" data-emblem-toggle aria-label="Редактировать символику" title="Редактировать символику"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 16.5V20h3.5L18 6 4 16.5Z"/><path d="m12.5 8 3.5 3.5M14 4l2-2 6 6-2 2"/></svg></button><div class="state-emblem-menu" data-emblem-menu hidden><button type="button" data-emblem-change>Загрузить / сменить</button><button type="button" class="danger-button" data-emblem-delete hidden>Удалить символику</button></div><input type="file" data-emblem-file accept="image/jpeg,image/png,image/webp" hidden>`:''}</div><div class="state-identity-facts"><div><small>Текущий правитель</small><strong data-current-ruler>Загружаю…</strong><small>Форма правления</small><strong>${escape(state.form_name||'Не задана')}</strong></div><div><small>Официальная раса</small><strong>${escape(state.official_race||'—')}</strong><small>Официальная религия</small><strong>${escape(state.official_religion||'—')}</strong></div></div></div><div class="state-dashboard-top"><section class="state-dashboard-card"><h4>Состояние государства</h4><div class="state-condition-list"><div><small>Лимит развития</small><strong>—</strong></div><div><small>Совокупное развитие</small><strong>${totalDevelopment===null?'—':totalDevelopment.toLocaleString('ru-RU')}</strong></div><div><small>Стабильность государства</small><strong data-state-stability>—</strong></div><div><small>Коррупция</small><strong>${Math.round(Number(state.corruption??.2)*100)}%</strong></div><div><small>Преступность</small><strong>${Math.round(crime*100)}%</strong></div></div></section><section class="state-dashboard-card"><h4>Население</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Показатель</th><th>Численность</th></tr></thead><tbody><tr><td>Городское</td><td>${Math.round(urbanPopulation).toLocaleString('ru-RU')}</td></tr><tr><td>Сельское</td><td>${Math.round(ruralPopulation).toLocaleString('ru-RU')}</td></tr><tr><td>Общее</td><td>${population.toLocaleString('ru-RU')}</td></tr></tbody></table></div></section></div><div class="state-dashboard-finances" data-state-finances><section class="state-dashboard-card"><h4>Казна</h4><div class="hint">Загружаю…</div></section><section class="state-dashboard-card"><h4>Престиж</h4><div class="hint">Загружаю…</div></section></div><h4>Советники правителя</h4>${advisorsTable}<h4>Сословия</h4>${estatesTable}${groupTable('Расы',groupStats('races',state.official_race),'race')}${groupTable('Религии',groupStats('religions',state.official_religion),'religion')}<p class="hint">Вес сословия суммирует ценность принадлежащих ему провинций; оккупант получает 50% веса. Влияние считается по всем пяти сословиям. Лояльность учитывает влияние, амбиции статуса и отклонение налоговой нагрузки от базовой. ${unresolvedTaxes?`Не рассчитано провинций по налогам: ${unresolvedTaxes}.`:''}</p><p class="hint">Каждую ставку можно менять раз в ход: 3 ОП за изменённую группу; администратору бесплатно.</p><div class="inline-actions"><button type="button" class="primary" data-tax-save-all disabled>Сохранить</button></div><p class="form-message" data-tax-save-message role="status"></p>`;
  }
  if(tab==='Экономика')detail='<div data-state-economy><p class="hint">Загружаю финансовые показатели…</p></div>';
  else if(tab==='Власть и династия')detail=`<div class="state-power-grid ${isAdmin?'admin':''}"><div class="state-power-overview"><div class="government-card"><small>Форма правления</small><strong>${escape(state.form_name||'Не задана')}</strong></div><div class="state-facts">${Object.entries(principles).map(([key,value])=>`<p><span>${escape(principleLabels[key]||key)}</span><strong>${escape(value)}</strong></p>`).join('')||'<p class="hint">Принципы государства не заданы.</p>'}</div></div><div data-succession-panel><p class="hint">Загружаю сведения о передаче власти…</p></div></div><div class="state-power-content" data-family-table></div>`;
  else if(tab==='Провинции')detail=`<p class="hint">Территорий государства: ${Number(state.province_count??ownedProvinces.length).toLocaleString('ru-RU')}; оккупировано у других государств: ${provinces.filter(p=>p.occupation===state.name&&p.layers?.states?.name!==state.name).length}. Рекрутский прирост — пополнение за ход, лимит — вместимость набора; запас рекрутов пока не ведётся. Оккупант получает 50% экономических показателей провинции. Нажмите заголовок, чтобы отсортировать таблицу.</p><div class="table-scroll provinces-table-scroll"><table class="state-data-table provinces-data-table"><thead><tr>${['Название провинции','ID','Раса','Религия','Тип пров.','Торговый статус','Принадлежность','Ресурс','Население','Рост населения','Ценность','КМ, %','Налоги','Торг. влияние','Производство','Прирост рекр.','Лимит рекр.'].map((label,index)=>`<th><button type="button" class="province-sort-button" data-sort-column="${index}" aria-label="Сортировать по столбцу ${label}">${label}<span aria-hidden="true"> ↕</span></button></th>`).join('')}</tr></thead><tbody>${provinces.length?provinces.map(p=>{const economy=calculateProvinceEconomy(p,state.name),value=calculateProvinceValue(p,state.name),occupied=p.occupation===state.name&&p.layers?.states?.name!==state.name;return `<tr class="${occupied?'occupied-province-row':''}"><td>${escape(p.name||'—')}${occupied?' · Оккупирована':''}</td><td>${p.id}</td><td>${escape(p.layers?.races?.name||'—')}</td><td>${escape(p.layers?.religions?.name||'—')}</td><td>${escape(p.province_type||'—')}</td><td>${escape(p.trade_status||'Отсутствует')}</td><td>${escape(p.belonging||'Отсутствует')}</td><td>${escape(p.layers?.resources?.name||'—')}</td><td>${Number(p.population||0).toLocaleString('ru-RU')}</td><td>${economy.populationGrowth===null?'—':economy.populationGrowth.toLocaleString('ru-RU')}</td><td>${value===null?'—':value.toLocaleString('ru-RU')}</td><td>${Number(p.control??100).toLocaleString('ru-RU')}%</td><td>${economy.taxes===null?'—':economy.taxes.toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})}</td><td>${economy.tradeInfluence===null?'—':economy.tradeInfluence.toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})}</td><td>${economy.production===null?'—':economy.production.toLocaleString('ru-RU')}</td><td>${economy.recruitGrowth===null?'—':economy.recruitGrowth.toLocaleString('ru-RU')}</td><td>${economy.recruitLimit===null?'—':economy.recruitLimit.toLocaleString('ru-RU')}</td></tr>`}).join(''):'<tr><td colspan="17" class="hint">У государства пока нет провинций.</td></tr>'}</tbody></table></div>`;
  else if(tab==='Экономика')detail=`<div data-state-economy><p class="hint">Загружаю финансовые показатели…</p></div>`;
  else if(tab==='Дипломатия')detail=`<div data-state-diplomacy><p class="hint">Загружаю дипломатические предложения…</p></div>`;
  else if(tab==='Торговля')detail=`<div data-state-trade><p class="hint">Загружаю торговые данные…</p></div>`;
  else if(tab==='Производство'){
    const resourceGroups=[...new Set(productionRows.map(row=>row.category))];
    const rows=resourceGroups.map(category=>`<tr class="resource-category-row"><th colspan="6">${escape(category)}</th></tr>${productionRows.filter(row=>row.category===category).map(row=>`<tr><td>${escape(row.resource)}</td><td>${row.production===null?'—':row.production.toLocaleString('ru-RU')}</td><td>${row.consumption.toLocaleString('ru-RU')}</td><td class="${row.balance===null?'':row.balance>0?'balance-positive':row.balance<0?'balance-negative':''}">${row.balance===null?'—':row.balance.toLocaleString('ru-RU')}</td><td>—</td><td>—</td></tr>`).join('')}`).join('');
    const unresolved=productionRows.filter(row=>row.unresolved).length;
    detail=`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Ресурс</th><th>Производство</th><th>Потребление</th><th>Баланс</th><th>Импорт</th><th>Экспорт</th></tr></thead><tbody>${rows}</tbody></table></div><p class="hint">Производство рассчитано по назначенному ресурсу, населению, типу провинции и контролю, затем уменьшено на преступность государства (${Math.round(crime*100)}%). Потребление = ROUNDUP(население / 10 × коэффициент). Эфемерная и Магическая пустоши в таблицу не включаются. ${unresolved?`Не рассчитано ресурсных строк: ${unresolved} из-за отсутствующих входных данных.`:''} Импорт/экспорт не рассчитываются; запасы не ведутся.</p>`;
  }
  host.innerHTML=`<div class="state-menu stack">${isAdmin?'<button id="state-back" type="button">← Все государства</button>':''}<div class="state-heading"><span class="state-color" style="background:${escape(state.color||'#777777')}"></span><h3>${escape(state.name)}</h3></div>${isAdmin?`<nav class="state-subtabs" aria-label="Разделы государства">${STATE_SECTIONS.map(name=>`<button type="button" data-state-tab="${escape(name)}" class="${name===tab?'active':''}">${escape(name)}</button>`).join('')}</nav>`:''}<section class="state-detail"><h3>${escape(tab)}</h3>${detail}</section>${isAdmin?'<button id="state-delete" class="danger-button" type="button">Удалить государство</button>':''}</div>`;
  if(tab==='Провинции'){
    const scroll=host.querySelector('.provinces-table-scroll'),table=scroll?.querySelector('.provinces-data-table');
    if(table){
      table.querySelectorAll('tbody tr').forEach(row=>{
        const id=Number(row.cells[1]?.textContent),province=provinces.find(item=>Number(item.id)===id);
        const editable=province&&(isAdmin||canRenameProvince(Number(state.id)))&&(isAdmin||Number(province.layers?.states?.id)===Number(state.id));
        if(!editable)return;
        const cell=row.cells[0],name=province.name||'';
        cell.innerHTML=`<input type="text" maxlength="120" required data-province-name="${id}" data-original-value="${escape(name)}" value="${escape(name)}" aria-label="Название провинции ${id}">`;
      });
      if(table.querySelector('[data-province-name]')){
        const actions=document.createElement('div');actions.className='inline-actions province-name-actions';actions.innerHTML='<button type="button" data-province-name-save disabled>Сохранить названия</button><p class="form-message" data-province-name-message role="status"></p>';
        scroll.after(actions);
        const inputs=[...table.querySelectorAll('[data-province-name]')],save=actions.querySelector('[data-province-name-save]');
        const refreshSave=()=>{save.disabled=!inputs.some(input=>input.value.trim()!==input.dataset.originalValue);};
        inputs.forEach(input=>input.addEventListener('input',refreshSave));
        save.onclick=async()=>{
          const changed=inputs.filter(input=>input.value.trim()!==input.dataset.originalValue);
          if(changed.some(input=>!input.value.trim())){showStatus('Название провинции не может быть пустым',3500);return;}
          save.disabled=true;
          try{
            for(const input of changed){const id=Number(input.dataset.provinceName),path=isAdmin?`admin/provinces/${id}`:`provinces/${id}/name`;await api(path,{method:'PATCH',body:JSON.stringify({name:input.value.trim()})});input.dataset.originalValue=input.value.trim();}
            showStatus('Названия провинций сохранены',3500);if(changed.length)emit('map:refresh');
          }catch(error){showStatus(error.message,5000);}
          finally{refreshSave();}
        };
      }
    }
  }
  if(tab==='Статистика'){loadStateFinances(host,Number(state.id),isAdmin);loadTaxEditor(host,Number(state.id),isAdmin);}
  if(tab==='Экономика')renderStateEconomy(host,Number(state.id),isAdmin,()=>renderStateDetails(host,state,tab,provinces,isAdmin));
  if(tab==='Дипломатия')renderDynasticDiplomacy(host.querySelector('[data-state-diplomacy]'),{stateId:Number(state.id)});
  if(tab==='Торговля')renderTradeAgreements(host.querySelector('[data-state-trade]'),Number(state.id));
  if(tab==='Власть и династия'){
    const familyHost=host.querySelector('[data-family-table]');
    const route=`${isAdmin?'admin':'my'}/states/${Number(state.id)}/characters`;
    const successionRoute=`${isAdmin?'admin':'my'}/states/${Number(state.id)}/succession`;
    const familyRequests=[api(route)];
    if(!isAdmin)familyRequests.push(api(`my/states/${Number(state.id)}/birth-events`),api(`my/states/${Number(state.id)}/marriage-candidates`));
    familyRequests.push(api(successionRoute));
    Promise.all(familyRequests).then(results=>{
      const characters=results[0],birthEvents=isAdmin?[]:results[1],marriageInfo=isAdmin?null:results[2],successionInfo=isAdmin?results[1]:results[3];
      if(!familyHost?.isConnected)return;
      const familyTable=characters.length?`<div class="table-scroll"><table class="state-data-table family-character-table"><thead><tr><th>Имя</th><th>Фамилия</th><th>Родство</th><th>Возраст</th><th>Раса</th><th>Религия</th><th>Наследование</th><th>Статус</th></tr></thead><tbody>${characters.map(person=>`<tr class="${person.alive?'':'family-character-dead'}"><td>${escape(person.title?`${person.title} `:'')}${escape(person.name||'—')}${person.is_current_ruler?' <small>(правитель)</small>':''}${person.is_regent?' <small>(регент)</small>':''}</td><td>${escape(person.surname||'—')}</td><td>${escape(person.relationship||'Родственник')}${person.state_name&&person.state_name!==state.name?` · ${escape(person.state_name)}`:''}</td><td>${Number(person.age)} лет</td><td>${escape(person.race||'—')}</td><td>${escape(person.religion||'—')}</td><td>${escape(person.legitimacy||'Неприменимо')}</td><td>${person.alive?'Жив':'Мёртв'}</td></tr>`).join('')}</tbody></table></div>`:'<p class="hint">Профиль правителя ещё не заполнен.</p>';
      const birthForms=birthEvents.map(event=>`<form class="application-panel birth-naming-form" data-birth-event="${event.id}"><strong>Рождение · ${event.children.length} ${event.children.length===1?'ребёнок':'ребёнка'}</strong>${event.children.map((child,index)=>`<label class="field"><span>${child.gender}, ${escape(categories.find(item=>item.layer==='races'&&item.id===Number(child.race_id))?.name||'раса не указана')} · имя ${index+1}</span><input name="child-name" maxlength="120" required></label>`).join('')}<button class="primary" type="submit">Сохранить имена</button></form>`).join('');
      const marriageCandidates=marriageInfo?.candidates?.length?`<section class="application-panel"><h4>Поиск местного супруга</h4><p class="hint">Заключение брака стоит 10 ОП. Поддержка кандидатов сословиями отображается отдельно.</p><div class="marriage-candidates">${marriageInfo.candidates.map(candidate=>`<article class="application-panel marriage-candidate"><strong>${escape(candidate.name)} ${escape(candidate.surname)}</strong><span>${Number(candidate.age)} лет · ${escape(candidate.race)} · ${escape(candidate.religion)}</span><span class="hint">Поддерживают: ${escape(candidate.supported_by?.join(', ')||'пока никто')}</span><button type="button" data-marry-candidate="${candidate.id}">Заключить брак · 10 ОП</button></article>`).join('')}</div></section>`:(!characters.some(person=>person.relationship==='Супруга'||person.relationship==='Супруг')&&marriageInfo?.message?`<p class="hint">${escape(marriageInfo.message)}</p>`:'');
      const successionCandidates=successionInfo?.candidates||[];
      const successionPanel=`${successionInfo?.pending?`<section class="application-panel succession-panel"><h4>${successionInfo.event_type==='election'?'Выборы правителя':'Выбор наследника'}</h4><p>${escape(successionInfo.reason)}. После выбора кандидат вступит в должность при смене хода ${Number(successionInfo.resolves_turn)}. Престиж будет установлен на 10 ОП.</p>${successionInfo.chosen?'<p class="hint">Кандидат выбран; ожидается смена хода.</p>':`<div class="marriage-candidates">${successionCandidates.map((candidate,index)=>`<article class="application-panel marriage-candidate"><strong>${escape(candidate.name)} ${escape(candidate.surname)}</strong><span>${Number(candidate.age)} лет · ${escape(candidate.gender)} · ${escape(candidate.race||'—')} · ${escape(candidate.religion||'—')}</span>${candidate.support?`<span class="hint">Поддерживают: ${escape(Object.entries(candidate.support).filter(([,supported])=>supported).map(([group])=>group).join(', ')||'нет сословий')}</span>`:''}${candidate.support_votes!==undefined?`<span class="hint">Поддержка провинций: ${Number(candidate.support_votes)}</span>`:''}<button type="button" data-succession-choice="${index+1}">Выбрать кандидата</button></article>`).join('')}</div>`}</section>`:''}${!isAdmin?`<section class="application-panel succession-panel"><h4>Передача власти</h4>${principles.authority==='Династия'?`<label class="field"><span>Назначить законного наследника · 15 ОП и −15 п.п. ключевым сословиям</span><select data-designated-heir><option value="">Выберите живого законного ребёнка</option>${characters.filter(person=>person.alive&&person.relationship==='Ребёнок'&&person.legitimacy==='Законный').map(person=>`<option value="${person.id}" ${Number(successionInfo?.designated_heir_id)===Number(person.id)?'selected':''}>${escape(person.name)} ${escape(person.surname)} · ${person.age}</option>`).join('')}</select></label><button type="button" data-designate-heir ${characters.some(person=>person.alive&&person.relationship==='Ребёнок'&&person.legitimacy==='Законный')?'':'disabled'}>Назначить наследника</button>`:''}${principles.authority==='Диктат'?`<label class="field"><span>Назначенный преемник</span><select data-designated-successor><option value="">Выберите персонажа</option>${characters.filter(person=>person.alive&&Number(person.age)>=16).map(person=>`<option value="${person.id}" ${Number(successionInfo?.designated_successor_id)===Number(person.id)?'selected':''}>${escape(person.name)} ${escape(person.surname)} · ${person.age}</option>`).join('')}</select></label><button type="button" data-designate-successor>Назначить преемника</button>`:''}<button type="button" class="danger-button" data-abdicate>Отречься от власти</button></section>`:''}`;
      const successionHost=host.querySelector('[data-succession-panel]');
      if(successionHost)successionHost.innerHTML=successionPanel||(!isAdmin?'<section class="application-panel succession-panel"><h4>Передача власти</h4><button type="button" class="danger-button" data-abdicate>Отречься от власти</button></section>':'');
      familyHost.innerHTML=`${birthForms}${!isAdmin?marriageCandidates:''}<section class="family-registry"><h4>Правитель и семья</h4>${familyTable}</section>`;
      familyHost.querySelectorAll('.birth-naming-form').forEach(form=>form.onsubmit=async event=>{event.preventDefault();const names=[...form.querySelectorAll('[name="child-name"]')].map(input=>input.value.trim());const button=form.querySelector('[type="submit"]');button.disabled=true;try{await api(`my/states/${Number(state.id)}/birth-events/${form.dataset.birthEvent}/name`,{method:'POST',body:JSON.stringify({names})});showStatus('Имена детей сохранены',3000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      familyHost.querySelectorAll('[data-marry-candidate]').forEach(button=>button.onclick=async()=>{if(!confirm('Заключить местный брак и потратить 10 ОП?'))return;button.disabled=true;try{await api(`my/states/${Number(state.id)}/marriages/local`,{method:'POST',body:JSON.stringify({candidate_id:Number(button.dataset.marryCandidate)})});showStatus('Брак заключён',3000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      successionHost?.querySelectorAll('[data-succession-choice]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{await api(`${successionRoute}/events/${Number(successionInfo.id)}/choose`,{method:'POST',body:JSON.stringify({candidate:Number(button.dataset.successionChoice)})});showStatus('Преемник выбран; вступление состоится при указанной смене хода',5000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      successionHost?.querySelector('[data-abdicate]')?.addEventListener('click',async event=>{const button=event.currentTarget;if(!confirm('Отречение необратимо и немедленно запустит передачу власти. Продолжить?'))return;button.disabled=true;try{await api(`my/states/${Number(state.id)}/abdicate`,{method:'POST',body:JSON.stringify({confirmed:true})});showStatus('Отречение принято; начата передача власти',5000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      for(const [kind,selector] of [['heir','[data-designate-heir]'],['successor','[data-designate-successor]']])successionHost?.querySelector(selector)?.addEventListener('click',async event=>{const button=event.currentTarget;const select=successionHost.querySelector(kind==='heir'?'[data-designated-heir]':'[data-designated-successor]');if(!select?.value){showStatus('Сначала выберите персонажа',3500);return;}if(kind==='heir'&&!confirm('Назначение стоит 15 ОП и снизит лояльность ключевых сословий на 15 п.п. Подтвердить?'))return;button.disabled=true;try{await api(`my/states/${Number(state.id)}/designate`,{method:'POST',body:JSON.stringify({kind,character_id:Number(select.value)})});showStatus(kind==='heir'?'Наследник назначен':'Преемник назначен',4000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
    }).catch(error=>{if(familyHost?.isConnected)familyHost.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;});
  }
  if(tab==='Статистика'){
    bindStateEmblem(host,state,isAdmin);
    const rulerTarget=host.querySelector('[data-current-ruler]');
    api(`${isAdmin?'admin':'my'}/states/${Number(state.id)}/characters`).then(characters=>{
      if(!rulerTarget?.isConnected)return;
      const ruler=characters.find(person=>person.is_current_ruler&&person.alive);
      rulerTarget.textContent=ruler?`${ruler.title?`${ruler.title} `:''}${ruler.name} ${ruler.surname||''}`.trim():'Нет действующего правителя';
    }).catch(error=>{if(rulerTarget?.isConnected)rulerTarget.textContent='Не удалось загрузить';});
    api(`${isAdmin?'admin':'my'}/states/${Number(state.id)}/politics`).then(rows=>{
      if(!host.isConnected||!Array.isArray(rows))return;
      const politics=new Map(rows.map(row=>[`${row.group_type}:${row.group_key}`,row]));
      const derived=calculateStatePolitics(provinces,rows,state.name);
      host.querySelectorAll('[data-politics-status]').forEach(cell=>{const row=politics.get(cell.dataset.politicsStatus);if(row)cell.textContent=row.status;});
      host.querySelectorAll('[data-politics-loyalty]').forEach(cell=>{const key=cell.dataset.politicsLoyalty,row=politics.get(key),loyalty=key.startsWith('estate:')?derived.estateLoyalty[key.slice(7)]:Number(row?.loyalty);if(Number.isFinite(loyalty))cell.textContent=`${(loyalty*100).toLocaleString('ru-RU',{maximumFractionDigits:1})}%`;});
      host.querySelectorAll('[data-estate-influence]').forEach(cell=>{const value=derived.estateInfluence[cell.dataset.estateInfluence];if(Number.isFinite(value))cell.textContent=pct(value);});
      host.querySelectorAll('[data-politics-stability]').forEach(cell=>{const key=cell.dataset.politicsStability,row=politics.get(key);if(!row)return;const value=key.startsWith('estate:')?derived.estateStability[key.slice(7)]:null;if(value!==null&&value!==undefined)cell.textContent=`${(value*100).toLocaleString('ru-RU',{maximumFractionDigits:2})}%`;});
      const stability=host.querySelector('[data-state-stability]');if(stability)stability.textContent=`${(derived.stateStability*100).toLocaleString('ru-RU',{maximumFractionDigits:1})}%`;
    }).catch(error=>showStatus(`Не удалось загрузить лояльность: ${error.message}`,4500));
  }
  if(tab==='Провинции'){
    const table=host.querySelector('.provinces-data-table');
    const directions=new Map();
    table?.querySelectorAll('[data-sort-column]').forEach(button=>button.addEventListener('click',()=>{
      const column=Number(button.dataset.sortColumn),direction=directions.get(column)===1?-1:1;
      directions.clear();directions.set(column,direction);
      const rows=[...table.tBodies[0].rows];
      const numeric=value=>{
        const cleaned=value.replace(/[\s\u00a0%]/g,'').replace(',','.');
        return /^-?\d+(?:\.\d+)?$/.test(cleaned)?Number(cleaned):null;
      };
      rows.sort((a,b)=>{
        const cellValue=cell=>cell?.querySelector('input')?.value.trim()||cell?.textContent.trim()||'';
        const left=cellValue(a.cells[column]),right=cellValue(b.cells[column]);
        const leftBlank=!left||left==='—',rightBlank=!right||right==='—';
        if(leftBlank!==rightBlank)return leftBlank?1:-1;
        const leftNumber=numeric(left),rightNumber=numeric(right);
        const comparison=leftNumber!==null&&rightNumber!==null?leftNumber-rightNumber:left.localeCompare(right,'ru',{numeric:true,sensitivity:'base'});
        return comparison*direction;
      });
      rows.forEach(row=>table.tBodies[0].append(row));
      table.querySelectorAll('.province-sort-button span').forEach((indicator,index)=>{indicator.textContent=index===column?(direction===1?' ▲':' ▼'):' ↕';});
      table.querySelectorAll('th').forEach((header,index)=>header.setAttribute('aria-sort',index===column?(direction===1?'ascending':'descending'):'none'));
    }));
  }
  if(isAdmin){
    host.querySelector('#state-back').onclick=()=>renderStatesContent(host);
    host.querySelectorAll('[data-state-tab]').forEach(button=>button.onclick=()=>renderStatesContent(host,state.id,button.dataset.stateTab));
    host.querySelector('#state-delete').onclick=async()=>{
      if(!confirm(`Удалить государство «${state.name}»? Его провинции станут нейтральными, назначения игрокам удалятся, маркеры останутся без государства.`))return;
      const button=host.querySelector('#state-delete');button.disabled=true;
      try{await api(`admin/states/${state.id}`,{method:'DELETE',body:'{}'});stateRows=stateRows.filter(row=>row.id!==state.id);categories=categories.filter(c=>!(c.layer==='states'&&c.id===state.id));renderStatesContent(host);emit('map:refresh');showStatus(`Государство «${state.name}» удалено`,3500);}
      catch(error){button.disabled=false;showStatus(error.message,5000);}
    };
  }
}

function bindStateEmblem(host,state,isAdmin){
  const image=host.querySelector('[data-state-emblem]');
  const placeholder=host.querySelector('[data-emblem-placeholder]');
  const menu=host.querySelector('[data-emblem-menu]');
  const deleteButton=host.querySelector('[data-emblem-delete]');
  const toggle=host.querySelector('[data-emblem-toggle]');
  const fileInput=host.querySelector('[data-emblem-file]');
  const setImage=data=>{
    if(!image)return;
    image.hidden=!data;image.src=data||'';
    placeholder.hidden=Boolean(data);
    if(deleteButton)deleteButton.hidden=!data;
  };
  image?.addEventListener('error',()=>setImage(null));
  api(`state-emblem/${state.id}`).then(result=>{if(host.isConnected)setImage(result.emblem_url);}).catch(error=>showStatus(`Не удалось загрузить символику: ${error.message}`,4500));
  if(!isAdmin)return;
  toggle.addEventListener('click',()=>{menu.hidden=!menu.hidden;});
  menu.querySelector('[data-emblem-change]').addEventListener('click',()=>fileInput.click());
  fileInput.addEventListener('change',async event=>{
    const file=event.target.files?.[0];if(!file)return;
    if(file.size>2*1024*1024){showStatus('Изображение символики должно быть не больше 2 МБ',4000);fileInput.value='';return;}
    if(!['image/jpeg','image/png','image/webp'].includes(file.type)){showStatus('Допустимы только JPG, JPEG, PNG или WebP',4000);fileInput.value='';return;}
    try{
      const image_data=await readImageData(file);
      await api(`admin/state-emblem/${state.id}`,{method:'POST',body:JSON.stringify({image_data})});
      setImage(image_data);menu.hidden=true;showStatus('Символика государства обновлена',3000);
    }catch(error){showStatus(error.message,5000);}finally{fileInput.value='';}
  });
  deleteButton.addEventListener('click',async()=>{
    try{
      await api(`admin/state-emblem/${state.id}`,{method:'POST',body:JSON.stringify({image_data:null})});
      setImage(null);menu.hidden=true;showStatus('Символика государства удалена',3000);
    }catch(error){showStatus(error.message,5000);}
  });
}

async function renderStatesMenu(host){
  host.innerHTML='<p class="hint">Загружаю государства…</p>';
  try{stateRows=await api('admin/states');if(!host.isConnected)return;const pending=pendingStateNavigation;pendingStateNavigation=null;if(pending&&stateRows.some(row=>Number(row.id)===Number(pending.stateId)))renderStatesContent(host,pending.stateId,pending.tab);else renderStatesContent(host);}
  catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

function renderStatesContent(host,selectedId=null,tab='Статистика',create=false){
  if(!host.isConnected)return;
  const state=stateRows.find(row=>row.id===Number(selectedId));
  if(state){
    const local=allProvinces.filter(p=>p.kind==='land'&&(Number(p.layers?.states?.id)===state.id||p.occupation===state.name));
    renderStateDetails(host,state,tab,local,true);
    return;
  }
  const stateList=stateRows.map(row=>`<button class="state-list-row" type="button" data-open-state="${row.id}"><span class="state-color" style="background:${escape(row.color)}"></span><span>${escape(row.name)}</span><small>${row.players?.length?'Игрок':row.is_npc?'NPC':'Без владельца'} · ${Number(row.province_count)} пров.</small></button>`).join('');
  const principleFields=Object.entries({authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина',ephemeral:'Эфемерный вопрос'}).map(([key,label])=>`<label class="field"><span>${label}</span><select name="${key}" required>${PRINCIPLES[key].map(value=>`<option value="${escape(value)}">${escape(value)}</option>`).join('')}</select></label>`).join('');
  host.innerHTML=`<div class="state-menu stack"><div class="state-menu-heading"><h3>Государства</h3><button id="state-create-toggle" type="button">${create?'Список государств':'Создать NPC государство'}</button></div>${create?`<form id="state-create-form" class="stack"><label class="field"><span>Название</span><input name="name" maxlength="100" required></label><label class="field"><span>Цвет</span><input name="color" type="color" value="#ac805d" required></label>${principleFields}<label class="field"><span>Официальная раса</span><select name="race_id" required>${categories.filter(c=>c.layer==='races').map(c=>`<option value="${c.id}">${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>Официальная религия</span><select name="religion_id" required>${categories.filter(c=>c.layer==='religions').map(c=>`<option value="${c.id}">${escape(c.name)}</option>`).join('')}</select></label><h4>Начальный правитель</h4><label class="field"><span>Имя</span><input name="ruler_name" maxlength="100" required></label><label class="field"><span>Фамилия</span><input name="ruler_surname" maxlength="120" required></label><label class="field"><span>Пол</span><select name="ruler_gender"><option>Мужской</option><option>Женский</option><option>Иной</option></select></label><label class="field"><span>Титул</span><input name="ruler_title" maxlength="100" required></label><label class="field"><span>Возраст (16–250)</span><input name="ruler_age" type="number" min="16" max="250" value="30" required></label><p id="state-form-preview" class="hint"></p><p id="state-form-message" class="form-message" role="status"></p><button class="primary" type="submit">Создать государство</button></form>`:`<div class="state-list">${stateList||'<p class="hint">Государства ещё не созданы.</p>'}</div>`}</div>`;
  host.querySelector('#state-create-toggle').onclick=()=>renderStatesContent(host,null,'Статистика',!create);
  host.querySelectorAll('[data-open-state]').forEach(button=>button.onclick=()=>renderStatesContent(host,button.dataset.openState));
  const form=host.querySelector('#state-create-form');if(!form)return;
  form.setAttribute('role','dialog');form.setAttribute('aria-label','Создать NPC государство');
  const updatePreview=()=>{const selection=Object.fromEntries(new FormData(form));const problem=principleConflict(selection);const preview=host.querySelector('#state-form-preview');preview.textContent=problem||`Форма правления: ${governmentName(selection)}`;preview.classList.toggle('invalid',!!problem);form.querySelector('[type=submit]').disabled=!!problem;};
  form.querySelectorAll('select').forEach(select=>select.onchange=updatePreview);updatePreview();
  form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('[type=submit]');button.disabled=true;const payload=Object.fromEntries(new FormData(form));payload.race_id=Number(payload.race_id);payload.religion_id=Number(payload.religion_id);payload.ruler_age=Number(payload.ruler_age);
    try{const created=await api('admin/states',{method:'POST',body:JSON.stringify(payload)});stateRows.push(created);categories.push({layer:'states',id:created.id,name:created.name,color:created.color});renderStatesContent(host,created.id);emit('map:refresh');showStatus('NPC государство создано',3000);}
    catch(error){host.querySelector('#state-form-message').textContent=error.message;button.disabled=false;}
  };
}
export function initUI(notify){
  showStatus=notify;
  for(const[key,[name,icon,side]]of Object.entries(PANELS)){
    const button=document.createElement('button');button.className='dock-button';button.id=`panel-${key}`;button.dataset.panel=key;button.title=name;button.setAttribute('aria-label',name);button.setAttribute('aria-expanded','false');button.innerHTML=`<img src="assets/icons/${icon}.svg" alt="">`;
    if(key==='admin')button.hidden=true;button.onclick=()=>togglePanel(key);$(`${side}-dock`).append(button);
  }
  $('advance-turn').onclick=async()=>{
    const button=$('advance-turn');if(user?.role!=='admin'||button.disabled)return;
    if(!confirm('Рассчитать налоги, зачислить их в казны государств и перейти на следующий год и ход?'))return;
    button.disabled=true;button.textContent='Расчёт…';
    try{renderCalendar(await api('admin/turn/advance',{method:'POST',body:JSON.stringify({expected_year:gameCalendar.year,expected_turn:gameCalendar.turn})}));showStatus('Налоги начислены, содержание армии оплачено, долг обновлён; год и ход увеличены на 1',5000);}
    catch(error){showStatus(error.message,6000);}
    finally{button.disabled=false;button.textContent='Сменить ход';}
  };
  $('close-drawer').onclick=closeDrawer;$('close-legend').onclick=closeLegend;$('close-modal').onclick=()=>$('modal').close();
  $('modal').addEventListener('click',e=>{if(e.target===$('modal'))$('modal').close();});
  const observer=new ResizeObserver(queueLayout);observer.observe($('selection'));observer.observe($('map-scale'));
  window.addEventListener('resize',queueLayout);
  window.addEventListener('keydown',e=>{if(e.key==='Escape'){closeAllDrawers();emit('map:tool','');toolMode='';}});
  window.addEventListener('tools:result',e=>{lastToolResult=e.detail;if($('tool-result'))$('tool-result').textContent=e.detail;queueLayout();});
}
let gameCalendar={year:1452,turn:1};
function renderCalendar(calendar){gameCalendar={year:Number(calendar.year),turn:Number(calendar.turn)};$('calendar-label').textContent=`${gameCalendar.year.toLocaleString('ru-RU')} год / ${gameCalendar.turn.toLocaleString('ru-RU')} ход`;}
export function hydrateUI(data){categories=data.categories;allProvinces=data.provinces;provinceAdjacency=data.adjacency||{};roadsList=data.roads||[];if(data.economy_config){economyDraft=data.economy_config;setEconomyConfig(data.economy_config);}emit('map:settings',settings);api('game/calendar').then(renderCalendar).catch(e=>showStatus(e.message,4000));api('auth/me').then(result=>acceptUser(result.user)).catch(e=>showStatus(e.message,4000));}
window.addEventListener('map:selection-changed',e=>{selectedProvince=e.detail||null;});
window.addEventListener('application:province-picked',e=>{
  if(!applicationDraft||!applicationPickMode)return;
  const province=e.detail;
  if(applicationPickMode==='capital'){applicationDraft.capital_province_id=Number(province.id);applicationPickMode=null;emit('application:pick',null);showStatus('',0);renderMenu('Профиль');return;}
  const id=Number(province.id),ids=applicationDraft.province_ids;
  applicationDraft.province_ids=ids.includes(id)?ids.filter(value=>Number(value)!==id):[...ids,id].slice(0,5);
  emit('application:selection-updated',{ids:applicationDraft.province_ids});
  if(applicationDraft.province_ids.length===5){applicationPickMode=null;emit('application:pick',null);showStatus('Пять провинций выбраны. Проверьте связность и выберите столицу.',3500);renderMenu('Профиль');}
});
window.addEventListener('map:marker-location-selected',async e=>{try{const marker=await api('admin/markers',{method:'POST',body:JSON.stringify({...pendingMarkerDraft,...e.detail})});emit('map:marker-created',marker);pendingMarkerDraft=null;const form=$('marker-create-form');if(form){form.reset();form.querySelector('button[type="submit"]').textContent='Указать точку на карте';form.querySelector('button[type="submit"]').disabled=false;$('cancel-marker-placement').hidden=true;$('marker-province').textContent='Заполните поля, затем укажите точку на карте.';}showStatus('Маркер создан в выбранной точке',2500);}catch(error){pendingMarkerDraft=null;emit('map:place-marker',null);showStatus(error.message,5000);const form=$('marker-create-form');if(form){form.querySelector('button[type="submit"]').textContent='Указать точку на карте';form.querySelector('button[type="submit"]').disabled=false;$('cancel-marker-placement').hidden=true;}}});
window.addEventListener('map:marker-created',e=>{mapMarkers.push(e.detail);if(current==='admin')updateMarkerAdminList($('marker-create-form')?.closest('.panel-group'));});
window.addEventListener('map:marker-deleted',e=>{mapMarkers=mapMarkers.filter(m=>m.id!==e.detail);if(current==='admin')updateMarkerAdminList($('marker-create-form')?.closest('.panel-group'));});
window.addEventListener('map:refreshed',e=>{categories=e.detail.categories;allProvinces=e.detail.provinces;provinceAdjacency=e.detail.adjacency||provinceAdjacency;mapMarkers=e.detail.markers||[];tradeAvailability={};roadsList=e.detail.roads||[];if(e.detail.economy_config){setEconomyConfig(e.detail.economy_config);if(!economyDirty)economyDraft=e.detail.economy_config;}if(current==='admin')renderDrawer();if(legendOpen)renderLegend();const host=$('menu-section');if(host?.isConnected&&activeMenuSection==='Константы'&&!host.querySelector('input:focus,select:focus,textarea:focus'))renderEconomyConstants(host);else if(host?.isConnected&&STATE_SECTIONS.includes(activeMenuSection)&&!host.querySelector('input:focus,select:focus,textarea:focus'))renderPlayerStateSection(host,activeMenuSection,true);});
window.addEventListener('roads:progress',e=>{roadInfo=e.detail;if(current==='admin'&&adminTool==='roads')renderDrawer();});
window.addEventListener('roads:saved',e=>{roadsList.push(e.detail);if(current==='admin'&&adminTool==='roads')renderDrawer();});
let markerPopover=null;
function closeMarkerPopover(){markerPopover?.remove();markerPopover=null;}
window.addEventListener('map:close-marker-popup',closeMarkerPopover);
function positionMarkerPopover({x,y,visible}){
  if(!markerPopover)return;
  markerPopover.hidden=!visible;
  if(!visible)return;
  const rect=markerPopover.getBoundingClientRect(),gap=12,margin=8;
  const left=x+gap+rect.width<=innerWidth-margin?x+gap:x-gap-rect.width;
  const top=y+gap+rect.height<=innerHeight-margin?y+gap:y-gap-rect.height;
  markerPopover.style.left=`${Math.max(margin,Math.min(innerWidth-rect.width-margin,left))}px`;
  markerPopover.style.top=`${Math.max(margin,Math.min(innerHeight-rect.height-margin,top))}px`;
}
window.addEventListener('map:marker-position',event=>{
  if(markerPopover?.dataset.markerId===String(event.detail.id))positionMarkerPopover(event.detail);
});
window.addEventListener('map:marker-selected',event=>{
  if(!isAdmin())return;
  closeMarkerPopover();
  const marker=event.detail,box=document.createElement('section');box.className='surface marker-popover';box.setAttribute('role','dialog');box.setAttribute('aria-label','Информация о маркере');
  const header=document.createElement('header'),title=document.createElement('h2');title.textContent=`${MARKERS[marker.type]||marker.type}: ${marker.name}`;
  const close=document.createElement('button');close.type='button';close.className='icon-button';close.textContent='×';close.setAttribute('aria-label','Закрыть');close.onclick=closeMarkerPopover;header.append(title,close);box.append(header);
  const content=document.createElement('div');content.className='marker-popover-content';
  for(const [label,value] of [['Название',marker.name],['Тип',MARKERS[marker.type]||marker.type],['Государство',marker.state_name||'—'],['ID провинции',marker.province_id],['Координаты',`${Number(marker.x).toFixed(1)}, ${Number(marker.y).toFixed(1)}`]]){const row=document.createElement('p');row.textContent=`${label}: ${value}`;content.append(row);}
  const remove=document.createElement('button');remove.type='button';remove.className='marker-popover-delete';remove.textContent='Удалить маркер';remove.onclick=async()=>{if(!window.confirm(`Удалить маркер «${marker.name}»?`))return;remove.disabled=true;try{await api(`admin/markers/${marker.id}`,{method:'DELETE'});emit('map:marker-deleted',Number(marker.id));closeMarkerPopover();showStatus('Маркер удалён',2000);}catch(error){remove.disabled=false;showStatus(error.message,5000);}};
  box.append(content,remove);box.dataset.markerId=String(marker.id);document.body.append(box);markerPopover=box;
  positionMarkerPopover({x:event.detail.screenX,y:event.detail.screenY,visible:true});
});
