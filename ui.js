import {supabaseApi,supabaseLogin,loadSupabaseInitialMap,hasAuthenticatedSession,militaryApi,militaryMovementApi,militiaApi,garrisonApi,estateInvestmentApi,estateSocialApi,estateFiscalApi,colonizationApi,adminResourcesApi,adminModifiersApi} from './supabase-api.js?v=admin-modifiers-20261028';
import {PRINCIPLES,governmentName,principleConflict} from './state-principles.js';
import {calculateProvinceEconomy,calculateProvinceEstateTaxes,calculateProvinceValue,calculateStateProduction,calculateStatePolitics,calculateInternalTradeForecast,calculateTradeZoneForecast,distributeTradeZoneIncome,getEconomyConfig,setEconomyConfig,GROUP_STATUS_EFFECTS,GROUP_STATUS_LOYALTY_MODIFIERS,ESTATE_INFLUENCE_FACTORS} from './economy.js?v=20261025173000';
import {estatePopulation} from './estate-demography.js';
import {renderWall} from './wall.js?v=wall-comments-20261028';
import {renderRules} from './rules.js?v=rules-headings-20261029';
import {renderMilitaryPanel,renderMilitaryDiplomacy,renderMilitaryContract,renderMilitaryAdminQueue} from './military-ui.js?v=mobile-audit-20261028';
const $=id=>document.getElementById(id);
export const LAYERS={states:'Государства',races:'Расы',religions:'Религии',resources:'Ресурсы',trade:'Торговые зоны',climate:'Климат',population:'Плотность населения',development:'Развитие',military:'Военный'};
const MARKERS={capital:'Столица',city:'Город',fortress:'Крепость',port:'Порт'};
const INFO={roads:'Дороги',routes:'Торговые пути',provinces:'Названия провинций',states:'Названия государств',races:'Названия рас',religions:'Названия религий',resources:'Названия ресурсов',trade:'Названия торговых зон'};
const STATE_SECTIONS=['Статистика','Провинции','Экономика','Торговля','Дипломатия','Власть и династия','Военное дело','Модификаторы'];
const PANELS={legend:['Легенда','list','left'],control:['Управление','sliders-horizontal','right'],markers:['Маркеры','map-pin','right'],info:['Информация','info','right'],tools:['Инструменты','ruler','right'],admin:['Администрирование','shield','right']};
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const emit=(name,detail)=>window.dispatchEvent(new CustomEvent(name,{detail}));
let current=null,user=null,categories=[],allProvinces=[],provinceAdjacency={},mapMarkers=[],activeColonies=[],selectedProvince=null,pendingMarkerDraft=null,toolMode='',lastToolResult='',saveTimer,showStatus=()=>{},adminEditing=false,paintField='climate',paintValue='',paintActive=false,legendOpen=false,stateRows=[],applicationDraft=null,applicationPickMode=null,unreadNotificationCount=0,notificationFetchToken=0,activeMenuSection='Профиль',tradeRoutePick=null,pendingStateNavigation=null,activeContractType='dynastic_marriage',tradeAvailability={},tradeProposalDraft={fromStateId:null,toStateId:null,route:[],fromGoods:[{name:'',quantity:0}],toGoods:[{name:'',quantity:0}],fromGold:0,toGold:0};
let lastStateSection='Статистика',lastAdminStateId=null,lastAdminStateTab='Статистика',pendingProvinceId=null,activePortPlacementUI=null;
let provinceColumnPreset='Основное',provinceSearchQuery='';
let headerResourceToken=0;
let visibleGarrisonsByProvince=new Map();
let pendingDiplomacyStateId=null;
const stateEmblemCache=new Map();
const TRADE_STATUS_VALUES=['Отсутствует','Устье реки','Природный порт','Центр торговли I','Центр торговли II','Центр торговли III'];
const BULK_FIELDS=[['race','Раса'],['religion','Религия'],['state','Государство'],['occupation','Оккупация'],['population','Население'],['trade_status','Торговый статус'],['resource','Ресурс'],['trade','Торговая зона'],['development','Развитие'],['control','Контроль, %'],['climate','Климат'],['terrain_type','Тип местности'],['capital','Маркер столицы'],['city','Маркер города']];
let bulkRules=[{condition_field:'climate',condition_value:'Холодный',target_field:'population',target_value:2000},{condition_field:'climate',condition_value:'Умеренный',target_field:'population',target_value:4000},{condition_field:'climate',condition_value:'Тропический',target_field:'population',target_value:5000}],bulkPreview=null,bulkBusy=false;
const panelPages={};let layoutFrame=0;
let adminTool='manual',colorLayer='resources',colorCategoryId=null;
const ADMIN_TOOLS={manual:'Ручное редактирование',bulk:'Массовое редактирование',markers:'Создать маркер',colors:'Цвета параметров',roads:'Прокладывание дорог'};
let economyDraft=null,economyLoading=false,economyDirty=false;
let militiaCoefficient=null,militiaCoefficientLoading=false;
let armyBudget={state_id:null,units:[],treasury:0,debt:0},armyBudgetLoading=false,armyBudgetDirty=false,armyReport=null;
const ROAD_TYPES={trail:'Тропа',highway:'Тракт',imperial:'Имперская'};
let roadsList=[],roadInfo={active:false,busy:false,anchors:[],segments:[]},roadType='trail';
function roadMarkup(){
  const count=roadInfo.anchors.length;
  return group('Прокладывание дорог',`<label class="field"><span>Тип дороги</span><select id="road-type" ${roadInfo.active?'disabled':''}>${Object.entries(ROAD_TYPES).map(([key,name])=>`<option value="${key}" ${key===roadType?'selected':''}>${name}</option>`).join('')}</select></label><p class="hint">Клик по провинции — её центр. Клик по маркеру — сам маркер. Добавляйте соседние провинции последовательно. Пунктир — тропа, штрихи — тракт, сплошная линия — имперская дорога.</p>${roadInfo.active?`<div class="tool-result">Точек: ${count}${roadInfo.busy?' · Расчёт / сохранение…':''}</div><button id="road-undo" ${roadInfo.busy||!count?'disabled':''}>Убрать последнюю точку</button><button id="road-save" ${roadInfo.busy||count<2?'disabled':''}>Сохранить дорогу</button><button id="road-cancel" ${roadInfo.saving?'disabled':''}>Отмена</button>`:'<button id="road-start">Начать прокладывание</button>'}<p class="hint">Сохранённых дорог: ${roadsList.length}. Видимость переключается в панели «Информация → Дороги».</p>${roadsList.map(road=>`<div class="marker-admin-row"><span>№ ${road.id} · ${ROAD_TYPES[road.type]||escape(road.type)} · ${road.anchors.length} точек</span><button data-delete-road="${road.id}" ${roadInfo.busy?'disabled':''} aria-label="Удалить дорогу ${road.id}">×</button></div>`).join('')}`);
}
function armyBudgetMarkup(){
  const states=categories.filter(c=>c.layer==='states');
  const report=armyReport?.states?.length?`<div class="army-report"><strong>Отчёт за ${armyReport.year} год, ход ${armyReport.turn}</strong>${armyReport.states.map(s=>`<div class="army-report-row"><b>${escape(s.name)}</b><span>Содержание ${Number(s.army_upkeep||0).toLocaleString('ru-RU')} G · оплачено ${Number(s.army_upkeep_paid||0).toLocaleString('ru-RU')} G · долг +${Number(s.army_upkeep_arrears||0).toLocaleString('ru-RU')} G · погашено ${Number(s.debt_repaid||0).toLocaleString('ru-RU')} G · долг всего ${Number(s.treasury_debt||0).toLocaleString('ru-RU')} G${s.food_coverage_pct==null?'':` · продовольственная обеспеченность ${Number(s.food_coverage_pct).toLocaleString('ru-RU')}% (${Number(s.food_deficit_units||0).toLocaleString('ru-RU')} / ${Number(s.food_required_units||0).toLocaleString('ru-RU')} ед. дефицита / потребления)`}</span></div>`).join('')}<p class="hint">Обеспеченность считается после договоров и рыночного распределения. Преступность меняется после расчёта пищи с поправкой стабильности и влияет на производство следующего хода. Население автоматически не меняется.</p></div>`:'';
  return group('Содержание армии',`<label class="field"><span>Государство</span><select id="army-state">${states.map(s=>`<option value="${s.id}" ${Number(armyBudget.state_id)===Number(s.id)?'selected':''}>${escape(s.name)}</option>`).join('')}</select></label><div class="tool-result">Казна: ${Number(armyBudget.treasury||0).toLocaleString('ru-RU')} G</div><p class="hint">Расход за ход считается как количество × содержание одного юнита. Если средств недостаточно, казна становится отрицательной; до восстановления до 0 G государство теряет 2 ОП за ход. Ставка типа части общая для всех государств.</p><div class="army-unit-labels"><span>Название</span><span>Количество</span><span>G / юнит за ход</span><span></span></div><div class="army-unit-list">${armyBudget.units.map((unit,index)=>`<div class="army-unit-row"><input data-army-name="${index}" value="${escape(unit.name)}" maxlength="80" placeholder="Тип части" aria-label="Тип части"><input data-army-quantity="${index}" type="number" min="0" max="1000000" step="1" value="${Number(unit.quantity)||0}" aria-label="Количество"><input data-army-upkeep="${index}" type="number" min="0" max="1000000" step="0.01" value="${Number(unit.upkeep_per_unit)||0}" aria-label="Содержание на единицу, G"><button type="button" data-army-remove="${index}" aria-label="Удалить тип части">×</button></div>`).join('')}</div><button type="button" id="army-add">Добавить тип части</button><button type="button" id="army-save" ${armyBudgetLoading?'disabled':''}>${armyBudgetDirty?'Сохранить состав и ставки':'Сохранить'}</button><button type="button" id="army-report-load">Загрузить последний отчёт хода</button>${report}<p class="hint">Расчётная стоимость: ${armyBudget.units.reduce((sum,u)=>sum+(Number(u.quantity)||0)*(Number(u.upkeep_per_unit)||0),0).toLocaleString('ru-RU')} G за ход.</p>`);
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
  const table=(title,rows)=>group(title,`<h4>${escape(title)}</h4><div class="economy-config-grid">${rows.join('')}</div>`);
  const resources=(config.resources||[]).map((r,i)=>`<div class="economy-config-row"><strong>${escape(r.name)}</strong>${numberField(`resources.${i}.value`,'Ценность, G',r.value)}${numberField(`resources.${i}.production`,'Производство',r.production)}${numberField(`resources.${i}.consumption`,'Потребление',r.consumption)}</div>`);
  const types=Object.entries(config.provinceModifiers||{}).flatMap(([name,row])=>[['production','Множитель производства'],['trade','Множитель влияния'],['tradeBase','База торговли']].map(([key,label])=>numberField(`provinceModifiers.${name}.${key}`,`${name} · ${label}`,row[key])));
  const trade=Object.entries(config.tradeStatusModifiers||{}).map(([name,value])=>numberField(`tradeStatusModifiers.${name}`,`${name} · множитель`,value));
  const growth=Object.entries(config.raceGrowthModifiers||{}).map(([name,value])=>numberField(`raceGrowthModifiers.${name}`,`${name} · рост населения`,value));
  const recruitGrowth=Object.entries(config.recruitGrowthModifiers||{}).map(([name,value])=>numberField(`recruitGrowthModifiers.${name}`,`${name} · прирост рекрутов`,value));
  const recruitLimit=Object.entries(config.recruitLimitModifiers||{}).map(([name,value])=>numberField(`recruitLimitModifiers.${name}`,`${name} · лимит рекрутов`,value));
  const estateRecruit=Object.entries(config.estateRecruitModifiers||{}).map(([name,value])=>numberField(`estateRecruitModifiers.${name}`,`${name} · множитель лимита рекрутов`,value));
  const valueWeights=Object.entries(config.provinceValueWeights||{}).map(([name,value])=>numberField(`provinceValueWeights.${name}`,`${({gold:'Золото',trade:'Торговля',production:'Производство',recruits:'Рекруты',population:'Население'})[name]||name} · вес`,value,'0.0001'));
  const estateTaxGreed=Object.entries(config.estateTaxGreed||{}).map(([key,value])=>{const [status,estate]=key.split('|');return numberField(`estateTaxGreed.${key}`,`${status} · ${estate} · доля сословия`,value,.01,'1');});
  const effectField=(key,label,max='100')=>numberField(`stateEffects.${key}`,label,config.stateEffects?.[key],'.001',max);
  const stateEffects=table('Население',[
    effectField('urbanizationThreshold','Порог урбанизации (доля)','1'),effectField('urbanizationPenaltySlope','Штраф прироста на долю урбанизации'),effectField('urbanizationPenaltyCap','Предел штрафа урбанизации (доля)','1')
  ])+table('Управление',[
    effectField('overloadCorruptionPerRatio','Коррупция на 100% перегрузки, п.п.'),effectField('overloadCorruptionCapPP','Предел вклада перегрузки, п.п.'),effectField('corruptionRecoveryCapPP','Предел снижения коррупции за ход, п.п.'),effectField('corruptionGrowthCapPP','Предел роста коррупции за ход, п.п.'),effectField('corruptionLoyaltyDivisor','Делитель бонуса лояльности'),effectField('corruptionLoyaltyCap','Потолок бонуса лояльности (доля)','1')
  ])+table('Налоги',[
    effectField('corruptionTaxPenalty','Штраф сбора на долю коррупции','1'),effectField('crimeTaxPenalty','Штраф сбора на долю преступности','1')
  ])+table('Преступность',[
    effectField('crimePopulationPenalty','Штраф прироста населения на долю преступности','1'),effectField('crimeRecruitBonus','Бонус прироста рекрутов на долю преступности')
  ]);
  return `<form id="economy-config-form" class="stack"><p class="hint">Изменения сохраняются в Supabase и используются всеми клиентами при расчётах. Коэффициент оккупации закреплён на уровне 50%. Влияние участвует в распределении дефицитных ресурсов по правилам документа «Торговля».</p>${table('Модификаторы типов провинций',types)}${table('Распределение налогов по сословиям',estateTaxGreed)}${table('Торговые статусы',trade)}${table('Ресурсы',resources)}${stateEffects}${table('Расовые множители прироста населения',growth)}${table('Прирост рекрутов по типу провинции',recruitGrowth)}${table('Лимит рекрутов по типу провинции',recruitLimit)}${table('Лимит рекрутов по сословиям',estateRecruit)}${table('Веса ценности провинции',valueWeights)}${table('Влияние налогов на лояльность',[numberField('taxLoyaltySensitivity','Потеря лояльности на 100% превышения налога',config.taxLoyaltySensitivity,.05,'5')])}<p class="hint">Базовые ставки сословий: Знать 10 G, Духовенство 1 G, Горожане 3 G, Крестьяне 1 G на жителя. Повышение ставки снижает расчётную лояльность соответствующего сословия.</p><button class="primary" type="submit">Сохранить коэффициенты</button></form>`;
}
function renderEconomyConstants(host){
  if(user?.role!=='admin'){host.innerHTML='<h3>Константы</h3><p class="hint">Раздел доступен только администратору.</p>';return;}
  host.innerHTML=`<h3>Константы</h3><section class="application-panel"><h4>Ополчение</h4><form class="inline-actions" data-militia-coefficient><label class="field"><span>Общий коэффициент мобилизации</span><input name="coefficient" type="number" min="0" max="10" step="0.001" required value="${militiaCoefficient??''}" ${militiaCoefficient==null?'disabled':''}></label><button type="submit" ${militiaCoefficient==null?'disabled':''}>Сохранить</button></form><p class="hint" data-militia-coefficient-message aria-live="polite">${militiaCoefficient==null?'Загружаю коэффициент…':'Базовое значение — 1.'}</p></section>${economyDraft?economyConfigMarkup():'<p class="hint">Загружаю константы экономики…</p>'}`;
  const militiaForm=host.querySelector('[data-militia-coefficient]');
  militiaForm.onsubmit=async event=>{
    event.preventDefault();const button=militiaForm.querySelector('button'),message=host.querySelector('[data-militia-coefficient-message]');
    button.disabled=true;
    try{const result=await militiaApi('set_coefficient',null,{coefficient:Number(militiaForm.elements.coefficient.value)});militiaCoefficient=Number(result.coefficient);message.textContent='Коэффициент сохранён. Прогноз ополчения пересчитается при открытии подраздела.';}
    catch(error){message.textContent=error.message;}finally{button.disabled=false;}
  };
  if(militiaCoefficient==null&&!militiaCoefficientLoading){
    militiaCoefficientLoading=true;
    militiaApi('settings').then(result=>{militiaCoefficient=Number(result.coefficient);if(host.isConnected&&activeMenuSection==='Константы')renderEconomyConstants(host);})
      .catch(error=>{if(host.isConnected)host.querySelector('[data-militia-coefficient-message]').textContent=error.message;})
      .finally(()=>militiaCoefficientLoading=false);
  }
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
export const canRenameMarker=marker=>!!user&&(user.role==='admin'||marker?.state_id!=null&&user.state_ids?.includes(Number(marker.state_id)));
export const getCategories=()=>categories;
export function api(path,options={}){return supabaseApi(path,options);}
function hydrateDiplomacyFlags(root){
  if(!root)return;
  root.querySelectorAll('[data-state-flag]').forEach(async flag=>{
    const id=Number(flag.dataset.stateFlag);if(!id)return;
    try{let emblem=stateEmblemCache.get(id);if(!emblem){emblem=await api(`state-emblem/${id}`);stateEmblemCache.set(id,emblem||{});}if(emblem?.emblem_url){flag.style.backgroundImage=`url("${emblem.emblem_url}")`;flag.classList.add('has-emblem');}}
    catch{ /* The state color remains as a usable fallback when no emblem is available. */ }
  });
}
window.addEventListener('ui:hydrate-state-flags',event=>hydrateDiplomacyFlags(event.detail?.root));
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
function openModal(title,auth=false){closeDrawer();$('modal-title').textContent=title;$('modal').classList.toggle('auth-dialog',auth);if(!$('modal').open)$('modal').showModal();}
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
  if(field==='terrain_type')return `<select data-bulk-value="${side}" data-index="${index}"><option value="" ${value==null?'selected':''}>Не задано</option>${[['forest','Лес'],['marsh','Болото'],['plains','Равнины'],['hills','Холмы'],['mountains','Горы'],['high_mountains','Высокие горы']].map(([code,label])=>`<option value="${code}" ${value===code?'selected':''}>${label}</option>`).join('')}</select>`;
  if(field==='occupation')return `<select data-bulk-value="${side}" data-index="${index}"><option value="" ${value==null?'selected':''}>Не оккупирована</option>${categories.filter(c=>c.layer==='states').map(c=>`<option value="${escape(c.name)}" ${value===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
  if(field==='trade_status')return `<select data-bulk-value="${side}" data-index="${index}">${TRADE_STATUS_VALUES.map(v=>`<option value="${v}" ${value===v?'selected':''}>${v}</option>`).join('')}</select>`;
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
  const shellTop=$('app-brand').closest('.app-header').getBoundingClientRect().bottom+12;
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
    const top=shellTop;
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
    const d=drawer.getBoundingClientRect(),c=card.getBoundingClientRect(),s=scale.getBoundingClientRect();
    const overlaps=r=>d.left<r.right+8&&d.right>r.left-8;
    const top=shellTop;
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
    const fields=[['name','Название'],['race','Раса'],['religion','Религия'],['state','Государство'],['occupation','Оккупация'],['population','Население'],['trade_status','Торговый статус'],['resource','Ресурс'],['trade','Торговая зона'],['development','Развитие'],['control','Контроль, %'],['climate','Климат'],['terrain_type','Тип местности'],['capital','Маркер столицы'],['city','Маркер города']];
    const field=fields.some(([key])=>key===paintField)?paintField:'climate';
    let valueControl='';
    if(['race','religion','resource','climate'].includes(field)){
      const layer={race:'races',religion:'religions',resource:'resources',trade:'trade',climate:'climate'}[field];
      valueControl=`<select id="admin-paint-value"><option value="">— очистить значение —</option>${categories.filter(c=>c.layer===layer).map(c=>`<option value="${escape(c.name)}" ${paintValue===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
    }else if(field==='occupation')valueControl=`<select id="admin-paint-value"><option value="">— снять оккупацию —</option>${categories.filter(c=>c.layer==='states').map(c=>`<option value="${escape(c.name)}" ${paintValue===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
    else if(field==='terrain_type')valueControl=`<select id="admin-paint-value"><option value="">— убрать тип местности —</option>${[['forest','Лес'],['marsh','Болото'],['plains','Равнины'],['hills','Холмы'],['mountains','Горы'],['high_mountains','Высокие горы']].map(([code,label])=>`<option value="${code}" ${paintValue===code?'selected':''}>${label}</option>`).join('')}</select>`;
    else if(['capital','city'].includes(field))valueControl=`<select id="admin-paint-value"><option value="true" ${paintValue==='true'?'selected':''}>Включить</option><option value="false" ${paintValue==='false'?'selected':''}>Выключить</option></select>`;
    else if(field==='trade_status')valueControl=`<select id="admin-paint-value">${TRADE_STATUS_VALUES.map(v=>`<option value="${v}" ${paintValue===v?'selected':''}>${v}</option>`).join('')}</select>`;
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
  host.querySelectorAll('[data-bulk-field]').forEach(select=>select.onchange=()=>{const index=Number(select.dataset.index),side=select.dataset.bulkField,field=select.value;bulkRules[index][`${side}_field`]=field;bulkRules[index][`${side}_value`]=field==='trade_status'?'Отсутствует':['capital','city'].includes(field)?true:['population','development'].includes(field)?0:null;bulkPreview=null;renderDrawer();});
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
  if(settings.layer==='military')html+='<div class="military-legend"><div><i class="military-token army"><img src="assets/icons/military-army.svg?v=military-token-colors-20261027" alt=""></i><span>Армия</span></div><div><i class="military-token fleet"><img src="assets/icons/military-fleet.svg?v=military-token-colors-20261027" alt=""></i><span>Флотилия</span></div></div><p class="hint">Фишки армий и флотов видны согласно правилу тумана войны. Гарнизоны и их состав указаны в окне провинции.</p>';
  else if(entries.length)html+=entries.map(c=>`<div class="legend-row"><i class="legend-swatch" style="background:${/^#[0-9a-f]{6}$/i.test(c.color)?c.color:'#888'}"></i><span>${escape(c.name)}</span></div>`).join('');
  else if(['population','development'].includes(settings.layer)){
    const values=allProvinces.map(p=>settings.layer==='population'?(p.kind==='land'&&p.population!=null?Number(p.population):null):p.development).filter(v=>v!=null);
    html+=values.length?`<p>${settings.layer==='population'?'Население провинций: ':''}от ${Math.min(...values).toLocaleString('ru-RU')} до ${Math.max(...values).toLocaleString('ru-RU')}${settings.layer==='population'?' чел.':''}</p><div class="gradient-key"></div>`:'<p class="hint">Показатели пока не заполнены.</p>';
  }else html+='<p class="hint">Для выбранного слоя данные пока не назначены.</p>';
  host.innerHTML=group('Слой',html)+group('Местность','<div class="legend-row"><i class="terrain-swatch forest"></i><span>Лес</span></div><div class="legend-row"><i class="terrain-swatch marsh"></i><span>Болото</span></div>')+group('Территории','<div class="legend-row"><i class="legend-swatch" style="background:#ffe7d6"></i><span>Нейтральные территории</span></div><div class="legend-row"><i class="legend-swatch" style="background:#486370"></i><span>Море</span></div><div class="legend-row"><i class="legend-swatch" style="background:#1f87ad"></i><span>Озеро</span></div>');
  queueLayout();
}
function togglePanel(key){
  if(key==='admin'&&user?.role!=='admin')return;
  if(key==='legend'){
    legendOpen=!legendOpen;$('legend-drawer').hidden=!legendOpen;
    if(legendOpen)renderLegend();updateDockState();queueLayout();return;
  }
  if(current===key){closeDrawer();return;}
  current=key;$('drawer-title').textContent=PANELS[key][0];$('drawer').className=`surface drawer ${PANELS[key][2]}`;$('drawer').hidden=false;
  updateDockState();renderDrawer();
}
async function refreshHeaderResources(){
  const token=++headerResourceToken,stateId=Number(user?.state_ids?.[0]);
  const bar=$('header-resources');bar.hidden=!stateId;document.body.classList.toggle('has-state-resources',!!stateId);
  if(!stateId)return;
  for(const id of ['header-treasury','header-prestige','header-recruits'])$(id).textContent='—';
  try{
    const [data,military]=await Promise.all([api(`${user?.role==='admin'?'admin':'my'}/states/${stateId}/tax-rates`),militaryApi('snapshot',stateId)]);
    if(token!==headerResourceToken||Number(user?.state_ids?.[0])!==stateId)return;
    $('header-treasury').textContent=Math.floor(Number(data.buckets?.Корона)||0).toLocaleString('ru-RU');
    $('header-prestige').textContent=Math.floor(Number(data.prestige)||0).toLocaleString('ru-RU');
    $('header-recruits').textContent=Number(military.recruits||0).toLocaleString('ru-RU');
  }catch{/* The header keeps placeholders while state data is unavailable. */}
}
async function acceptUser(next){
  user=next;colonizationMilitaryCache.clear();if(user?.state_ids?.[0])void loadColonizationMilitary(Number(user.state_ids[0])).catch(()=>{});notificationFetchToken++;unreadNotificationCount=0;updateNotificationBadge();$('advance-turn').hidden=user?.role!=='admin';$('header-profile-name').textContent=user?.nickname||'Профиль';$('header-profile').setAttribute('aria-label',user?`Профиль: ${user.nickname}`:'Профиль');if(user?.role!=='admin'){adminEditing=false;paintActive=false;emit('map:admin-paint',null);emit('roads:cancel');}$('panel-admin').hidden=user?.role!=='admin';
  emit('auth:user-changed',user);
  void refreshHeaderResources();
  if(!user&&current==='admin')closeDrawer();
  if(user){void refreshUnreadNotificationCount();try{const stored=await api('preferences');settings={...settings,...stored,markers:{...settings.markers,...stored.markers},information:{...settings.information,...stored.information}};if(!LAYERS[settings.layer])settings.layer='states';save();}catch(e){showStatus(e.message,4000);}}
  if(!$('app-page').hidden)renderMenu(activeMenuSection,true);
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
    if(profile.role==='admin'){host.insertAdjacentHTML('beforeend','<section class="application-panel admin-resource-editor" data-admin-resource-editor><h3>Ресурсы государств</h3><p class="hint">Корректировка Казны руководящего центра, Престижа и Рекрутов.</p><p class="hint">Загружаю данные…</p></section><section class="application-panel admin-modifier-editor" data-admin-modifier-editor><h3>Конструктор модификаторов</h3><p class="hint">Загружаю каталог и действующие назначения…</p></section><div data-military-admin-queue></div>');void renderAdminResourceEditor(host.querySelector('[data-admin-resource-editor]'));void renderAdminModifierEditor(host.querySelector('[data-admin-modifier-editor]'));void renderMilitaryAdminQueue(host.querySelector('[data-military-admin-queue]'),{notify:message=>showStatus(message,4000)});}
    const avatarImage=host.querySelector('.profile-avatar');if(avatarImage)avatarImage.onerror=()=>{const fallback=document.createElement('span');fallback.className='profile-avatar profile-avatar-fallback';fallback.textContent=profile.nickname.slice(0,1).toUpperCase();avatarImage.replaceWith(fallback);};
    host.querySelector('#profile-avatar-file').onchange=async event=>{const file=event.target.files?.[0];if(!file)return;if(file.size>2*1024*1024){showStatus('Аватар должен быть не больше 2 МБ',4000);return;}try{const image_data=await readImageData(file);await api('profile/avatar',{method:'POST',body:JSON.stringify({image_data})});showStatus('Аватар обновлён',2500);renderProfile(host);}catch(error){showStatus(error.message,5000);}};
    host.querySelector('#profile-avatar-delete')?.addEventListener('click',async()=>{try{await api('profile/avatar',{method:'POST',body:JSON.stringify({image_data:null})});showStatus('Аватар удалён',2500);renderProfile(host);}catch(error){showStatus(error.message,5000);}});
    host.querySelector('#create-application')?.addEventListener('click',()=>{applicationDraft={province_ids:[],principles:Object.fromEntries(Object.entries(PRINCIPLES).map(([key,values])=>[key,values[0]])),state_color:'#657e91'};renderProfile(host,true);});
    host.querySelector('#admin-applications')?.addEventListener('click',()=>renderAdminApplications(host));
    host.querySelectorAll('[data-open-application]').forEach(button=>button.onclick=()=>showApplication(host,applications.find(item=>String(item.id)===button.dataset.openApplication)));
  }catch(error){host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}
async function renderAdminResourceEditor(panel){
  if(!panel)return;
  try{
    let states=await adminResourcesApi('snapshot');
    const resourceLabels={treasury:'Казна',prestige:'Престиж',recruits:'Рекруты'};
    panel.innerHTML=`<h3>Ресурсы государств</h3><p class="hint">Корректировка Казны руководящего центра, Престижа и Рекрутов.</p><form class="admin-resource-form"><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Государство</th><th>Параметр</th><th>Знак</th><th>Изменение</th><th>Текущее значение</th><th></th></tr></thead><tbody><tr><td><select name="state_id" required>${states.map(s=>`<option value="${Number(s.id)}">${escape(s.name)}</option>`).join('')}</select></td><td><select name="resource"><option value="treasury">Казна</option><option value="prestige">Престиж</option><option value="recruits">Рекруты</option></select></td><td><select name="sign" aria-label="Знак изменения"><option value="1">+</option><option value="-1">−</option></select></td><td><input name="amount" type="number" min="1" max="1000000000" step="1" value="1" required aria-label="Величина изменения"></td><td><strong data-current-resource></strong></td><td><button type="submit" class="primary">Применить</button></td></tr></tbody></table></div><p class="form-message" data-resource-message role="status"></p></form>`;
    const form=panel.querySelector('form'),current=panel.querySelector('[data-current-resource]'),message=panel.querySelector('[data-resource-message]');
    const getSelected=()=>states.find(s=>Number(s.id)===Number(form.elements.state_id.value));
    const updateCurrent=()=>{const state=getSelected(),key=form.elements.resource.value,value=Number(state?.[key]||0);current.textContent=`${value.toLocaleString('ru-RU')}${key==='treasury'?' G':key==='prestige'?' ОП':' чел.'}`;};
    form.elements.state_id.addEventListener('change',updateCurrent);form.elements.resource.addEventListener('change',updateCurrent);updateCurrent();
    form.addEventListener('submit',async event=>{
      event.preventDefault();const submit=form.querySelector('[type="submit"]');submit.disabled=true;message.textContent='';
      try{
        const delta=Number(form.elements.sign.value)*Number(form.elements.amount.value);
        const updated=await adminResourcesApi('adjust',Number(form.elements.state_id.value),form.elements.resource.value,delta);
        states=states.map(state=>Number(state.id)===Number(updated.id)?updated:state);updateCurrent();
        message.textContent=`${updated.name}: ${resourceLabels[form.elements.resource.value]} ${delta>0?'увеличен':'уменьшен'} на ${Math.abs(delta).toLocaleString('ru-RU')}.`;
        window.dispatchEvent(new Event('state:resources-changed'));window.dispatchEvent(new Event('map:refresh'));
      }catch(error){message.textContent=error.message;}
      finally{submit.disabled=false;}
    });
  }catch(error){panel.innerHTML=`<h3>Ресурсы государств</h3><p class="form-message">${escape(error.message)}</p>`;}
}
async function renderAdminModifierEditor(panel){
  if(!panel)return;
  const esc=escape;
  const shownValue=(value,unit)=>['%','п.п.'].includes(unit)?Number(value)*100:Number(value);
  try{
    let snapshot=await adminModifiersApi('snapshot');
    const render=()=>{
      const states=snapshot.states||[],provinces=snapshot.provinces||[],definitions=snapshot.definitions||[],assigned=snapshot.assigned||[];
      panel.innerHTML=`<h3>Конструктор модификаторов</h3><p class="hint">Назначайте существующие эффекты государству или отдельной провинции на заданное число ходов. Пустой срок означает постоянное действие.</p><form class="admin-modifier-form"><div class="inline-actions"><label>Объект <select name="target_kind"><option value="state">Государство</option><option value="province">Провинция</option></select></label><label data-target-state-label>Государство <select name="state_id">${states.map(s=>`<option value="${Number(s.id)}">${esc(s.name)}</option>`).join('')}</select></label><label data-target-province-label hidden>Провинция <select name="province_id">${provinces.map(p=>`<option value="${Number(p.id)}" data-state-id="${Number(p.state_id)}">${esc(p.name)} · ${esc(p.state_name)}</option>`).join('')}</select></label><label>Модификатор <select name="definition">${definitions.map((d,i)=>`<option value="${i}">${esc(d.effect)} · ${esc(d.source)} (${esc(shownValue(d.value,d.unit))} ${esc(d.unit)})</option>`).join('')}</select></label><label>Значение <input name="value" type="number" step="any" required></label><label>Срок, ходов <input name="duration" type="number" min="1" max="10000" step="1" placeholder="Постоянно"></label><button type="submit" class="primary">Назначить</button></div><p class="form-message" data-modifier-message role="status"></p></form><h4>Назначенные модификаторы</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Объект</th><th>Модификатор</th><th>Значение</th><th>Срок</th><th></th></tr></thead><tbody>${assigned.length?assigned.map(item=>`<tr><td>${esc(item.target_name)}</td><td>${esc(item.effect)}</td><td>${esc(shownValue(item.value,item.unit))} ${esc(item.unit)}</td><td>${item.remaining_turns===null?'Постоянный':`${Number(item.remaining_turns)} ход.`}</td><td><button type="button" data-delete-modifier="${Number(item.id)}">Удалить</button></td></tr>`).join(''):'<tr><td colspan="5" class="hint">Назначенных модификаторов нет.</td></tr>'}</tbody></table></div>`;
      const form=panel.querySelector('form'),kind=form.elements.target_kind,stateSelect=form.elements.state_id,provinceSelect=form.elements.province_id,defSelect=form.elements.definition,valueInput=form.elements.value;
      const filterProvinces=()=>{const stateId=stateSelect.value;[...provinceSelect.options].forEach(option=>option.hidden=option.dataset.stateId!==stateId);if(provinceSelect.selectedOptions[0]?.hidden)provinceSelect.value=[...provinceSelect.options].find(option=>!option.hidden)?.value||'';};
      const sync=()=>{panel.querySelector('[data-target-state-label]').hidden=kind.value==='province';panel.querySelector('[data-target-province-label]').hidden=kind.value!=='province';filterProvinces();const def=definitions[Number(defSelect.value)];valueInput.value=shownValue(def?.value??0,def?.unit);};
      kind.onchange=sync;stateSelect.onchange=sync;defSelect.onchange=sync;sync();
      form.onsubmit=async event=>{event.preventDefault();const message=form.querySelector('[data-modifier-message]'),button=form.querySelector('[type="submit"]'),def=definitions[Number(defSelect.value)],entered=Number(valueInput.value),storedValue=['%','п.п.'].includes(def?.unit)?entered/100:entered;button.disabled=true;try{await adminModifiersApi('assign',{target_kind:kind.value,state_id:Number(stateSelect.value),province_id:kind.value==='province'?Number(provinceSelect.value):null,definition_index:Number(defSelect.value),value:storedValue,duration_turns:form.elements.duration.value?Number(form.elements.duration.value):null});snapshot=await adminModifiersApi('snapshot');render();panel.querySelector('[data-modifier-message]').textContent='Модификатор назначен.';}catch(error){message.textContent=error.message;}finally{if(button.isConnected)button.disabled=false;}};
      panel.querySelectorAll('[data-delete-modifier]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{await adminModifiersApi('delete',{modifier_id:Number(button.dataset.deleteModifier)});snapshot=await adminModifiersApi('snapshot');render();}catch(error){showStatus(error.message,5000);button.disabled=false;}});
    };
    render();
  }catch(error){panel.innerHTML=`<h3>Конструктор модификаторов</h3><p class="form-message">${esc(error.message)}</p>`;}
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
  const principles=Object.entries(PRINCIPLES).map(([key,values])=>`<label class="field"><span>${({authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина'})[key]}</span><select name="${key}">${values.map(value=>`<option ${d.principles[key]===value?'selected':''}>${escape(value)}</option>`).join('')}</select></label>`).join('');
  const provinceLabels=d.province_ids.map(id=>allProvinces.find(p=>p.id===Number(id))?.name||`ID ${id}`).join(', ');
  host.innerHTML=`<form id="player-application-form" class="application-form stack"><h3>Анкета государства</h3><label class="field"><span>Название государства</span><input name="state_name" maxlength="100" required value="${escape(d.state_name||'')}"></label><label class="field"><span>Цвет на карте</span><input name="state_color" type="color" value="${escape(d.state_color||'#657e91')}"></label>${principles}<label class="field"><span>Имя правителя</span><input name="ruler_name" maxlength="100" required value="${escape(d.ruler_name||'')}"></label><label class="field"><span>Фамилия правителя</span><input name="ruler_surname" maxlength="120" required value="${escape(d.ruler_surname||'')}"></label><label class="field"><span>Пол правителя</span><select name="ruler_gender"><option>Мужской</option><option ${d.ruler_gender==='Женский'?'selected':''}>Женский</option></select></label><label class="field"><span>Титул правителя</span><input name="ruler_title" maxlength="100" required value="${escape(d.ruler_title||'')}"></label><label class="field"><span>Возраст правителя (от 30)</span><input name="ruler_age" type="number" min="30" required value="${escape(d.ruler_age||30)}"></label><label class="field"><span>Официальная раса</span><select name="race_id">${categories.filter(c=>c.layer==='races').map(c=>`<option value="${c.id}" ${Number(d.race_id)===c.id?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>Официальная религия</span><select name="religion_id">${categories.filter(c=>c.layer==='religions').map(c=>`<option value="${c.id}" ${Number(d.religion_id)===c.id?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>История и описание (<output id="history-count">${(d.history||'').length}</output>/1500–4000)</span><textarea name="history" minlength="1500" maxlength="4000" rows="8" required>${escape(d.history||'')}</textarea></label><section class="application-panel"><h3>Территория и столица</h3><p>${d.province_ids.length}/5 выбрано${provinceLabels?`: ${escape(provinceLabels)}`:''}</p><button id="pick-application-provinces" type="button">Выбрать провинции на карте</button><button id="pick-application-capital" type="button" ${d.province_ids.length!==5?'disabled':''}>${d.capital_province_id?'Изменить провинцию столицы':'Выбрать столицу на карте'}</button><p>Столица: ${escape(allProvinces.find(p=>p.id===Number(d.capital_province_id))?.name||'не выбрана')}</p><label class="field"><span>Название столицы</span><input name="capital_name" maxlength="120" required value="${escape(d.capital_name||'')}"></label></section><label class="field"><span>Флаг / символика (JPG, JPEG, PNG или WebP, до 2 МБ)</span><input id="application-emblem" type="file" accept="image/jpeg,image/png,image/webp" ${d.emblem_data?'':'required'}></label>${d.emblem_data?`<img class="application-emblem-preview" src="${d.emblem_data}" alt="Предпросмотр символики">`:''}<label class="check-row"><span>Я изучил Правила и Механики проекта</span><input name="rules_acknowledged" type="checkbox" required ${d.rules_acknowledged?'checked':''}></label><p id="application-form-message" class="form-message" role="status"></p><button class="primary" type="submit">Отправить анкету</button><button id="cancel-application" type="button">Отмена</button></form>`;
  const form=host.querySelector('#player-application-form');
  const emblemInput=form.querySelector('#application-emblem');
  if(d.emblem_data){emblemInput.hidden=true;const label=emblemInput.closest('label');const status=document.createElement('p');status.className='hint';status.textContent=`Загружено: ${d.emblem_file_name||'изображение символики'}`;const replace=document.createElement('button');replace.type='button';replace.textContent='Заменить изображение';replace.onclick=()=>emblemInput.click();label.append(status,replace);}
  const governmentPreview=document.createElement('section');governmentPreview.className='application-panel';governmentPreview.innerHTML='<h3>Форма правления</h3><p class="government-preview" role="status"></p>';
  form.elements.military.closest('.field').after(governmentPreview);
  const updateGovernmentPreview=()=>{const selection=Object.fromEntries(Object.keys(PRINCIPLES).map(key=>[key,form.elements[key].value]));const problem=principleConflict(selection),preview=governmentPreview.querySelector('.government-preview');preview.textContent=problem||governmentName(selection)||'Не удалось определить форму правления';preview.classList.toggle('invalid',!!problem);};
  Object.keys(PRINCIPLES).forEach(key=>form.elements[key].addEventListener('change',updateGovernmentPreview));updateGovernmentPreview();
  form.querySelector('[name=history]').oninput=e=>{d.history=e.target.value;host.querySelector('#history-count').value=e.target.value.length;};
  form.querySelectorAll('input,select').forEach(el=>el.addEventListener('change',()=>{if(el.name)d[el.name]=el.type==='checkbox'?el.checked:el.value;if(el.name in PRINCIPLES)d.principles[el.name]=el.value;if(el.name==='state_color')d.state_color=el.value;}));
  emblemInput.onchange=async e=>{const file=e.target.files?.[0];if(!file)return;if(file.size>2097152||!['image/jpeg','image/png','image/webp'].includes(file.type)){host.querySelector('#application-form-message').textContent='Нужен JPG, PNG или WebP до 2 МБ.';e.target.value='';return;}d.emblem_data=await readImageData(file);d.emblem_file_name=file.name;renderApplicationForm(host);};
  form.querySelector('#pick-application-provinces').onclick=()=>{applicationPickMode='provinces';emit('application:pick',{mode:'provinces',ids:d.province_ids});showMap();showStatus('Выберите пять свободных сухопутных провинций. Повторный щелчок снимает выбор.',0);};
  form.querySelector('#pick-application-capital').onclick=()=>{applicationPickMode='capital';emit('application:pick',{mode:'capital',ids:d.province_ids});showMap();showStatus('Выберите одну из пяти выбранных провинций для столицы.',0);};
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
    const labels={authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина'};
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
  const badge=$('header-notification-count'),button=$('header-notifications');
  if(!badge||!button)return;
  badge.hidden=unreadNotificationCount===0;
  badge.textContent=unreadNotificationCount>99?'99+':String(unreadNotificationCount);
  button.setAttribute('aria-label',unreadNotificationCount?`Уведомления: ${unreadNotificationCount} непрочитанных`:'Уведомления');
}
function setUnreadNotificationCount(rows){unreadNotificationCount=rows.filter(item=>!item.read).length;updateNotificationBadge();}
async function refreshUnreadNotificationCount(){
  const token=++notificationFetchToken;
  if(!user){unreadNotificationCount=0;updateNotificationBadge();return;}
  try{const rows=await api('notifications');if(token===notificationFetchToken&&user)setUnreadNotificationCount(rows);}catch{/* Keep the current badge state if a refresh temporarily fails. */}
}
window.addEventListener('focus',()=>{if(user)void refreshUnreadNotificationCount();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden&&user)void refreshUnreadNotificationCount();});
const sectionView=section=>section==='Стена'?'wall':section==='Правила и механики'?'rules':STATE_SECTIONS.includes(section)||section==='Государства'?'state':'utility';
function confirmLeaveEdits(){
  const host=$('menu-section');
  if(!host||$('app-page').hidden)return true;
  const edited=[...host.querySelectorAll('[data-province-name],[data-tax-estate],[data-group-status]')].some(input=>!input.disabled&&input.dataset.originalValue!==undefined&&input.value.trim()!==input.dataset.originalValue);
  return !edited||window.confirm('Есть несохранённые изменения. Перейти в другой раздел без сохранения?');
}
const routeHash=(section,stateId=null,tab='Статистика')=>`#view=${encodeURIComponent(section)}${section==='Государства'&&stateId?`&state=${Number(stateId)}&tab=${encodeURIComponent(tab)}`:''}`;
function sectionFromLocation(){
  const params=new URLSearchParams(location.hash.slice(1)),section=params.get('view')||'map';
  if(section==='Города'){history.replaceState({section:'Статистика'},'',routeHash('Статистика'));return 'Статистика';}
  if(section==='Государства'){
    const stateId=Number(params.get('state'))||null,tab=params.get('tab')||'Статистика';
    lastAdminStateId=stateId;lastAdminStateTab=STATE_SECTIONS.includes(tab)?tab:'Статистика';
    pendingStateNavigation=stateId?{stateId,tab:lastAdminStateTab}:null;
  }
  return section;
}
function updateTopNavigation(view){
  document.querySelectorAll('[data-top-view]').forEach(button=>{
    const active=button.dataset.topView===view;
    button.classList.toggle('active',active);
    if(active)button.setAttribute('aria-current','page');else button.removeAttribute('aria-current');
  });
}
function closeUtilityPopover(){
  const popover=$('utility-popover');if(!popover)return;
  popover.hidden=true;popover.dataset.kind='';
  for(const id of ['header-notifications','header-profile'])$(id)?.setAttribute('aria-expanded','false');
}
function showUtilityPopover(kind){
  const popover=$('utility-popover');
  if(!popover.hidden&&popover.dataset.kind===kind){closeUtilityPopover();return;}
  popover.hidden=false;popover.dataset.kind=kind;
  $('calendar-popover').hidden=true;$('calendar-toggle').setAttribute('aria-expanded','false');
  $('header-notifications').setAttribute('aria-expanded',String(kind==='notifications'));
  $('header-profile').setAttribute('aria-expanded',String(kind==='profile'));
  if(kind==='profile'){
    popover.innerHTML=`<div class="utility-menu"><strong>${escape(user?.nickname||'Профиль')}</strong><span class="hint">${user?.role==='admin'?'Администратор':user?'Игрок':'Гость'}</span><button type="button" data-open-profile>${user?'Открыть профиль':'Войти'}</button></div>`;
    popover.querySelector('[data-open-profile]').onclick=()=>{if(!confirmLeaveEdits())return;closeUtilityPopover();if(user)renderMenu('Профиль');else renderAuth();};
  }else if(user){
    void renderNotifications(popover).then(()=>{if(popover.hidden||popover.dataset.kind!=='notifications')return;const button=document.createElement('button');button.type='button';button.className='utility-all';button.textContent='Все уведомления';button.onclick=()=>{if(!confirmLeaveEdits())return;closeUtilityPopover();renderMenu('Уведомления');};popover.append(button);});
  }else{
    popover.innerHTML='<p class="hint">Войдите, чтобы увидеть уведомления.</p><button type="button" data-notification-login>Войти</button>';
    popover.querySelector('[data-notification-login]').onclick=()=>{closeUtilityPopover();renderAuth();};
  }
}
function showMap(fromHistory=false){
  $('app-page').hidden=true;document.body.dataset.view='map';closeDrawer();closeUtilityPopover();updateTopNavigation('map');
  $('calendar-popover').hidden=true;$('calendar-toggle').setAttribute('aria-expanded','false');
  if(!fromHistory&&location.hash!=='#view=map')history.pushState({section:'map'},'',routeHash('map'));
  document.title='Карта — Sixième Terre';
  queueLayout();
}
function renderMenu(section='Статистика',fromHistory=false){
  if(section==='Города')section='Статистика';
  if(section==='Карта'){showMap(fromHistory);return;}
  if(user?.role==='admin'&&STATE_SECTIONS.includes(section)){pendingStateNavigation={stateId:lastAdminStateId,tab:section};section='Государства';}
  const view=sectionView(section);
  if(view==='state'&&user?.role!=='admin'&&section==='Государства')section=lastStateSection;
  if(view==='state'&&section!=='Государства')lastStateSection=section;
  activeMenuSection=section;
  closeDrawer();
  closeUtilityPopover();
  $('app-page').hidden=false;document.body.dataset.view=view;updateTopNavigation(view);
  $('calendar-popover').hidden=true;$('calendar-toggle').setAttribute('aria-expanded','false');
  const tabs=$('page-tabs'),picker=$('page-tab-picker'),tabSelect=$('page-tab-select'),heading=$('page-heading'),content=$('menu-section');
  const isState=view==='state';
  heading.innerHTML=`<div><span class="page-eyebrow">${isState?'УПРАВЛЕНИЕ ГОСУДАРСТВОМ':'FAUXLORE'}</span><h1>${escape(isState?'Государство':section)}</h1></div>`;
  tabs.hidden=!isState||user?.role==='admin';
  picker.hidden=tabs.hidden;
  if(!tabs.hidden){
    tabs.innerHTML=STATE_SECTIONS.map(name=>`<button type="button" data-state-section="${escape(name)}" class="${name===section?'active':''}" ${name===section?'aria-current="page"':''}>${name==='Статистика'?'Обзор':escape(name)}</button>`).join('');
    tabs.querySelectorAll('[data-state-section]').forEach(button=>button.onclick=()=>{if(confirmLeaveEdits())renderMenu(button.dataset.stateSection);});
    tabSelect.innerHTML=STATE_SECTIONS.map(name=>`<option value="${escape(name)}" ${name===section?'selected':''}>${name==='Статистика'?'Обзор':escape(name)}</option>`).join('');
    tabSelect.onchange=()=>{if(confirmLeaveEdits())renderMenu(tabSelect.value);else tabSelect.value=section;};
  }else{tabs.replaceChildren();tabSelect.replaceChildren();}
  content.replaceChildren();
  $('app-page').scrollTop=0;
  const nextHash=routeHash(section,section==='Государства'?(pendingStateNavigation?.stateId||lastAdminStateId):null,pendingStateNavigation?.tab||lastAdminStateTab);
  if(!fromHistory&&location.hash!==nextHash)history.pushState({section},'',nextHash);
  document.title=`${isState?(section==='Статистика'?'Обзор':section):section} — Sixième Terre`;
  if(section==='Профиль')renderProfile(content);
  else if(section==='Стена')void renderWall(content,user,()=>window.dispatchEvent(new Event('state:resources-changed')));
  else if(section==='Государства'&&user?.role==='admin')renderStatesMenu(content);
  else if(section==='Уведомления'&&user)renderNotifications(content);
  else if(section==='Константы'&&user?.role==='admin')renderEconomyConstants(content);
  else if(STATE_SECTIONS.includes(section)&&user&&['Статистика','Провинции','Экономика','Торговля','Дипломатия','Власть и династия','Военное дело','Модификаторы'].includes(section))renderPlayerStateSection(content,section);
  else if(isState&&!user){content.innerHTML='<div class="empty-page"><h2>Государство</h2><p>Войдите, чтобы открыть игровые данные.</p><button type="button" id="state-login">Войти</button></div>';content.querySelector('#state-login').onclick=renderAuth;}
  else if(section==='Правила и механики')void renderRules(content);
  else content.innerHTML=`<div class="empty-page"><span class="badge">В РАЗРАБОТКЕ</span><h2>${escape(section)}</h2><p>Содержание раздела пока не опубликовано.</p></div>`;
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
  const inputs=[...host.querySelectorAll('[data-tax-estate]')];
  const statusInputs=[...host.querySelectorAll('[data-group-status]')];
  saveButton.disabled=true;
  try{
    const [data,politicsRows]=await Promise.all([api(`${isAdmin?'admin':'my'}/states/${stateId}/estate-tax-rates`),api(`${isAdmin?'admin':'my'}/states/${stateId}/politics`)]);if(!saveButton.isConnected)return;
    for(const input of inputs){const group=data.groups.find(row=>row.estate===input.dataset.taxEstate);if(!group)continue;input.value=Number(group.rate);input.disabled=!isAdmin&&group.changed_this_turn;input.title=group.changed_this_turn?'Эту ставку уже меняли в текущем ходу':isAdmin?'Изменение бесплатно':'Стоимость изменения — 3 ОП';input.dataset.originalValue=String(Number(group.rate));}
    for(const input of statusInputs){const type=input.dataset.groupType==='race'?'race':'religion',row=politicsRows.find(item=>item.group_type===type&&Number(item.group_key)===Number(input.dataset.groupId));if(!row)continue;input.value=row.status;input.dataset.originalValue=row.status;const fixed=row.status==='Официальная';input.disabled=fixed||(!isAdmin&&row.changed_this_turn);input.title=fixed?'Официальный статус закреплён регистрацией':row.changed_this_turn?'Эту группу уже меняли в текущем ходу':isAdmin?'Изменение бесплатно':'Стоимость смены статуса — 10 ОП';}
    saveButton.disabled=false;
    saveButton.onclick=async()=>{
      const changed=inputs.filter(input=>!input.disabled&&Number(input.value)!==Number(input.dataset.originalValue));
      const statusChanges=statusInputs.filter(input=>!input.disabled&&input.value!==input.dataset.originalValue);
      if(!changed.length&&!statusChanges.length){showStatus('Изменений нет',3000);return;}
      const requiredPrestige=changed.length*3+statusChanges.length*10;
      if(!isAdmin&&Number(data.prestige)<requiredPrestige){showStatus(`Для этих изменений нужно ${requiredPrestige} ОП`,4000);return;}
      for(const input of changed){const value=Number(input.value);if(!Number.isFinite(value)||value<0||value>10000){showStatus('Ставка должна быть от 0 до 10 000 G',4000);input.focus();return;}}
      saveButton.disabled=true;
      try{for(const input of changed)await api(`${isAdmin?'admin':'my'}/states/${stateId}/estate-tax-rates`,{method:'POST',body:JSON.stringify({estate:input.dataset.taxEstate,rate:Number(input.value)})});for(const input of statusChanges)await api(`${isAdmin?'admin':'my'}/states/${stateId}/politics`,{method:'PATCH',body:JSON.stringify({group_type:input.dataset.groupType,group_id:Number(input.dataset.groupId),status:input.value})});window.dispatchEvent(new Event('state:resources-changed'));showStatus(isAdmin?'Изменения сохранены':'Изменения сохранены; списано 3 ОП за ставку и 10 ОП за статус каждой группы',4500);await loadTaxEditor(host,stateId,isAdmin);}
      catch(error){saveButton.disabled=false;const message=host.querySelector('[data-tax-save-message]');if(message)message.textContent=error.message;showStatus(error.message,5000);}
    };
  }catch(error){saveButton.disabled=true;const message=host.querySelector('[data-tax-save-message]');if(message)message.textContent=error.message;}
}

async function renderStateEconomy(host,stateId,isAdmin,onRefresh=()=>{}){
  const target=host.querySelector('[data-state-economy]');if(!target)return;
  target.innerHTML='<p class="hint">Загружаю финансовые показатели…</p>';
  try{
    const [data,estateRateData,test,tradeData,stateList,indicators,loans,tradeOverview,colonyData,investmentData,garrisonData,socialData,fiscalData]=await Promise.all([api(`${isAdmin?'admin':'my'}/states/${stateId}/tax-rates`),api(`${isAdmin?'admin':'my'}/states/${stateId}/estate-tax-rates`),isAdmin?api('admin/turn/test'):Promise.resolve(null),api('my/trade-agreements'),api(isAdmin?'admin/states':'my/states'),api(`${isAdmin?'admin':'my'}/states/${stateId}/indicators`),api(`${isAdmin?'admin':'my'}/states/${stateId}/loans`),api(`${isAdmin?'admin':'my'}/states/${stateId}/trade-overview`).catch(()=>({})),colonizationApi('snapshot',stateId),estateInvestmentApi('snapshot',stateId),garrisonApi('snapshot',stateId),estateSocialApi('snapshot',stateId),estateFiscalApi('snapshot',stateId)]);
    if(!target.isConnected)return;
    const buckets=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
    const stateRecord={...stateList.find(item=>Number(item.id)===Number(stateId)),permanent_modifiers:indicators.permanent_modifiers||[]},stateName=stateRecord?.name||data.state_name;
    const stateRates=Object.fromEntries(estateRateData.groups.map(group=>[group.estate,Number(group.rate)]));
    const forecastProvinces=allProvinces.filter(p=>Number(p.layers?.states?.id)===Number(stateId)||p.occupation===stateName).map(p=>{
      const ownerMatch=Number(p.layers?.states?.id)===Number(stateId),layers={...p.layers};
      if(ownerMatch)layers.states={...layers.states,estate_tax_rates:stateRates};
      return {...p,layers,...(!ownerMatch?{occupation_estate_tax_rates:stateRates}:{})};
    });
    const config=getEconomyConfig(),estateOrder=['Знать','Духовенство','Горожане','Крестьяне'];
    const authorityStatus={'Династия':['Ключевое','Значимое','Бесправное','Бесправное'],'Магистрат':['Значимое','Ключевое','Ключевое','Бесправное'],'Клир':['Бесправное','Ключевое','Бесправное','Бесправное'],'Диктат':['Бесправное','Значимое','Бесправное','Бесправное'],'Вече':['Бесправное','Значимое','Значимое','Ключевое']};
    const economyStatus={'Крепостничество':['Ключевое','—','—','Бесправное'],'Гильдии':['—','—','Ключевое','—'],'Адмиралтейство':['—','—','Ключевое','—'],'Корсарство':['—','—','Значимое','—'],'Работорговля':['—','—','—','Бесправное']};
    const taxForecast={total:0,buckets:Object.fromEntries(buckets.map(name=>[name,0]))};
    const roundMoney=value=>Math.floor(Number(value)||0);
    for(const province of forecastProvinces){
      const lines=calculateProvinceEstateTaxes(province,stateName,stateRecord);if(!lines)continue;
      const principles=stateRecord?.principles||{};
      for(const [estate,line] of Object.entries(lines)){
        taxForecast.total+=line.net;const index=estateOrder.indexOf(estate);
        const economic=economyStatus[principles.economy]?.[index],status=economic&&economic!=='—'?economic:(authorityStatus[principles.authority]?.[index]||'—');
        const greed=Number(config.estateTaxGreed?.[`${status}|${estate}`]??0),center=roundMoney(line.net*(1-greed));
        taxForecast.buckets['Корона']+=center;taxForecast.buckets[estate]+=line.net-center;
      }
    }
    taxForecast.total=roundMoney(taxForecast.total);for(const name of buckets)taxForecast.buckets[name]=roundMoney(taxForecast.buckets[name]);
    const agreements=(tradeData.agreements||[]).filter(item=>item.status==='accepted'&&(Number(item.from_state_id)===Number(stateId)||Number(item.to_state_id)===Number(stateId)));
    const tradeGoldIn=roundMoney(agreements.reduce((sum,item)=>sum+Number((Number(item.from_state_id)===Number(stateId)?item.terms?.to_gold:item.terms?.from_gold)||0),0));
    const tradeGoldOut=roundMoney(agreements.reduce((sum,item)=>sum+Number((Number(item.from_state_id)===Number(stateId)?item.terms?.from_gold:item.terms?.to_gold)||0),0));
    const forecastTradeRows=calculateStateProduction(forecastProvinces,stateName,stateRecord);
    const stateModifierTotal=key=>(indicators.permanent_modifiers||[]).filter(item=>item.key===key&&item.scope==='Государство').reduce((sum,item)=>sum+Number(item.value||0),0);
    const internalTradeFactor=Math.max(0,1+stateModifierTotal('internal_trade_income'));
    const internalTradeForecast=calculateInternalTradeForecast(forecastTradeRows,Number(tradeOverview.internal_duty_rate??15)),tradeInternalIncome=roundMoney(internalTradeForecast.internalIncome*internalTradeFactor);
    const tradeMarketIncome=roundMoney(calculateTradeZoneForecast(allProvinces).reduce((sum,zone)=>sum+(zone.participants||[]).filter(participant=>Number(participant.state_id)===Number(stateId)||(participant.state_id==null&&participant.state_name===stateName)).reduce((income,participant)=>income+Number(participant.local_income||0)+Number(participant.export_income||0),0),0)*Math.max(0,1+stateModifierTotal('trade_zone_income')));
    const sponsorGarrison=Object.fromEntries(buckets.map(name=>[name,0]));
    for(const province of garrisonData.provinces||[]){
      const sponsor=buckets.includes(province.sponsor)?province.sponsor:'Корона';
      const troops=(province.units||[]).reduce((sum,unit)=>sum+Number(unit.quantity)*Number(unit.upkeep)*.4,0);
      const fort=Math.max(0,([0,100,200,300,400][Number(province.fort_level)||0]||0)-(province.free_fort?300:0));
      const walls=Math.max(0,([0,300,500,700][Number(province.wall_level)||0]||0)-(province.free_wall?300:0));
      sponsorGarrison[sponsor]+=troops+fort+walls;
    }
    const sponsoredTotal=buckets.slice(1).reduce((sum,name)=>sum+sponsorGarrison[name],0);
    const upkeep=roundMoney(Math.max(0,Number(data.army_upkeep_forecast||0)-sponsoredTotal)),colonyUpkeep=roundMoney((colonyData.missions||[]).length*1000);
    const zoneIncomeByEstate=distributeTradeZoneIncome(tradeMarketIncome),estateBudget=Object.fromEntries(buckets.map(name=>[name,{income:roundMoney(taxForecast.buckets[name]+Number(zoneIncomeByEstate[name]||0)+Number(internalTradeForecast.estateIncomeByName?.[name]||0)*internalTradeFactor+(name==='Корона'?tradeGoldIn:0)),expense:name==='Корона'?roundMoney(upkeep+colonyUpkeep+tradeGoldOut):roundMoney(sponsorGarrison[name])}]));
    for(const name of buckets)estateBudget[name].saldo=roundMoney(estateBudget[name].income-estateBudget[name].expense);
    const money=value=>`${roundMoney(value).toLocaleString('ru-RU')} G`,prestige=value=>`${roundMoney(value).toLocaleString('ru-RU')} ОП`;
    const testPanel=isAdmin?`<section class="application-panel"><h4>Проверка смены хода</h4><p class="hint">Тестовый ход запускает расчёты в игровой базе. Откат восстанавливает снимок, если после теста игровые данные не изменялись.</p><div class="inline-actions">${test.active?`<button type="button" class="danger-button" data-test-turn-rollback>Откатить тестовый ход (${Number(test.after_year)} / ${Number(test.after_turn)})</button>`:`<button type="button" data-test-turn-advance>Выполнить тестовый ход</button>`}</div><p class="hint">${test.active?`Можно вернуть календарь к ${Number(test.before_year)} году, ${Number(test.before_turn)} ходу.`:'После проверки откатите тестовый ход, чтобы восстановить игровые данные.'}</p></section>`:'';
    const treasuryIncomeRows=[['Налоговые поступления',taxForecast.buckets['Корона']],['Внутренняя торговля · пошлина',tradeInternalIncome],['Торговые зоны',zoneIncomeByEstate['Корона']],['Золото по договорам',tradeGoldIn],['Прочие разовые поступления',0]];
    const treasuryExpenseRows=[['Содержание армии',upkeep],['Содержание колоний',colonyUpkeep],['Платежи по торговым договорам',tradeGoldOut],['Погашение займов',0],['Прочие разовые списания',0]];
    const prestigeEffects=(indicators.permanent_modifiers||[]).filter(item=>item.key==='prestige'&&item.scope==='Государство');
    const prestigeIncomeRows=[...prestigeEffects.filter(item=>Number(item.value)>0).map(item=>[`${item.effect} · ${item.source}`,roundMoney(item.value)]),['Династический брак',0]];
    const prestigeExpenseRows=[...prestigeEffects.filter(item=>Number(item.value)<0).map(item=>[`${item.effect} · ${item.source}`,roundMoney(-Number(item.value))]),['Изменение налоговой ставки',0],['Местный брак',0],['Торговые предложения',0],['Назначение наследника',0],['Прочие списания',0]];
    const sumRows=rows=>roundMoney(rows.reduce((sum,[,value])=>sum+(Number(value)||0),0));
    const treasurySaldo=sumRows(treasuryIncomeRows)-sumRows(treasuryExpenseRows),prestigeSaldo=sumRows(prestigeIncomeRows)-sumRows(prestigeExpenseRows);
    const chartColors=['#75c78a','#e7c667','#69b1c8','#b38bd4','#e57970','#d99765','#91a15f','#bd7398'];
    const chartMarkup=(title,items,unit,compact=false)=>{const total=items.reduce((sum,item)=>sum+Math.max(0,Number(item.value)||0),0),circumference=2*Math.PI*38;let offset=0;const arcs=items.map((item,index)=>{const value=Math.max(0,Number(item.value)||0);if(!total||!value)return '';const length=value/total*circumference,arc=`<circle cx="50" cy="50" r="38" fill="none" stroke="${chartColors[index%chartColors.length]}" stroke-width="15" stroke-dasharray="${length} ${circumference-length}" stroke-dashoffset="${-offset}" transform="rotate(-90 50 50)"/>`;offset+=length;return arc;}).join('');const ring=!total?'<circle cx="50" cy="50" r="38" fill="none" stroke="#59605a" stroke-width="15"/>':arcs;return `<div class="economy-chart ${compact?'economy-chart-compact':''}"><h5>${title}</h5><div class="economy-chart-content"><div class="economy-chart-donut"><svg viewBox="0 0 100 100" role="img" aria-label="${title}: ${items.map(item=>`${item.label} ${unit(item.value)}`).join(', ')}">${ring}</svg><span>${total?unit(total):'Нет оборота'}</span></div><div class="economy-chart-legend">${items.map((item,index)=>`<div><i style="--chart-color:${chartColors[index%chartColors.length]}"></i><span>${item.label}</span><strong>${unit(item.value)}</strong></div>`).join('')}</div></div></div>`;};
    const sourceBlock=(title,rows,unit,kind)=>{const total=sumRows(rows),items=rows.map(([label,value])=>({label,value}));return `<section class="application-panel economy-source-card ${kind}"><h4>${title}</h4><div class="economy-source-body"><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Источник</th><th>Прогноз</th></tr></thead><tbody>${rows.map(([name,value])=>`<tr><td>${name}</td><td>${unit(value)}</td></tr>`).join('')}<tr class="economy-source-total"><td><strong>Итого</strong></td><td><strong>${unit(total)}</strong></td></tr></tbody></table></div>${chartMarkup('По источникам',items,unit,true)}</div></section>`;};
    const summaryCard=(name,current,saldo,next,unit)=>`<section class="application-panel economy-summary-card"><h4>${name}</h4><dl><div><dt>Текущая сумма</dt><dd>${unit(current)}</dd></div><div><dt>Сальдо · прогноз</dt><dd class="${saldo>0?'balance-positive':saldo<0?'balance-negative':'balance-neutral'}">${saldo>0?'+':''}${unit(saldo)}</dd></div><div><dt>На следующий ход · прогноз</dt><dd>${unit(next)}</dd></div></dl></section>`;
    const flowCard=(title,income,expense,unit)=>`<section class="application-panel economy-flow-card"><h4>${title}</h4>${chartMarkup('Соотношение доходов и расходов',[{label:'Доходы',value:income},{label:'Расходы',value:expense}],unit)}</section>`;
    target.innerHTML=`${testPanel}<div class="economy-overview-grid">${summaryCard('Казна',roundMoney(data.buckets?.Корона||0),treasurySaldo,roundMoney(data.buckets?.Корона||0)+treasurySaldo,money)}${summaryCard('Престиж',roundMoney(data.prestige||0),prestigeSaldo,roundMoney(data.prestige||0)+prestigeSaldo,prestige)}${flowCard('Казна · доходы и расходы',sumRows(treasuryIncomeRows),sumRows(treasuryExpenseRows),money)}${flowCard('Престиж · доходы и расходы',sumRows(prestigeIncomeRows),sumRows(prestigeExpenseRows),prestige)}</div><div class="economy-ledger-grid">${sourceBlock('Доходы Казны',treasuryIncomeRows,money,'treasury-income')}${sourceBlock('Доходы Престижа',prestigeIncomeRows,prestige,'prestige-income')}${sourceBlock('Расходы Казны',treasuryExpenseRows,money,'treasury-expense')}${sourceBlock('Расходы Престижа',prestigeExpenseRows,prestige,'prestige-expense')}</div><section class="application-panel economy-loans-panel"><h4>Займы Казны</h4><p class="hint">5% к сумме займа, срок — 5 ходов. Просрочка снижает лояльность кредитора на 5 п.п. Отрицательная казна списывает 2 ОП за ход.</p><form class="estate-loan-borrow"><label class="field">Кредитор <select name="lender">${buckets.slice(1).map(name=>`<option value="${name}">${name} · ${Number(loans.buckets?.[name]||0).toLocaleString('ru-RU')} G</option>`).join('')}</select></label><label class="field">Сумма, G <input name="amount" type="number" min="1" step="1" required></label><button type="submit">Взять в долг</button></form><div class="table-scroll"><table class="state-data-table estate-loans-table"><thead><tr><th>Кредитор</th><th>Взято</th><th>К возврату</th><th>Остаток</th><th>Срок: ход</th><th>Погашение</th></tr></thead><tbody>${(loans.loans||[]).map(item=>`<tr><td>${escape(item.lender)}${item.overdue?' · просрочено':''}</td><td>${Number(item.principal).toLocaleString('ru-RU')}</td><td>${Number(item.total_due).toLocaleString('ru-RU')}</td><td>${Number(item.remaining).toLocaleString('ru-RU')}</td><td>${Number(item.due_turn)}</td><td>${Number(item.remaining)>0?`<form class="estate-loan-repay" data-loan-id="${Number(item.id)}"><input name="amount" type="number" min="1" max="${Math.floor(Number(item.remaining))}" step="1" value="${Number(item.remaining)}" required><button type="submit">Вернуть</button></form>`:'Погашено'}</td></tr>`).join('')||'<tr><td colspan="6">Займов пока нет.</td></tr>'}</tbody></table></div></section>`;
    target.querySelector('.estate-loan-borrow')?.addEventListener('submit',async event=>{event.preventDefault();const form=event.currentTarget,button=form.querySelector('button');button.disabled=true;try{await api(`${isAdmin?'admin':'my'}/states/${stateId}/loans/borrow`,{method:'POST',body:JSON.stringify({lender:form.elements.lender.value,amount:Number(form.elements.amount.value)})});window.dispatchEvent(new Event('state:resources-changed'));showStatus('Займ оформлен.',4000);void renderStateEconomy(host,stateId,isAdmin,onRefresh);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
    target.querySelectorAll('.estate-loan-repay').forEach(form=>form.addEventListener('submit',async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{await api(`${isAdmin?'admin':'my'}/states/${stateId}/loans/${form.dataset.loanId}/repay`,{method:'POST',body:JSON.stringify({amount:Number(form.elements.amount.value)})});window.dispatchEvent(new Event('state:resources-changed'));showStatus('Погашение записано.',4000);void renderStateEconomy(host,stateId,isAdmin,onRefresh);}catch(error){button.disabled=false;showStatus(error.message,5000);}}));
    const last=indicators.last_turn;
    const condition=document.createElement('section');condition.className='application-panel';
    condition.innerHTML=`<h4>Причины изменения состояния</h4>${last?.crime_rate_after_pct==null?'<p class="hint">Нет отчёта с изменением преступности.</p>':`<div class="table-scroll"><table class="state-data-table state-condition-report"><tbody>${[
      ['Обеспеченность пищей',`${Number(last.food_coverage_pct).toLocaleString('ru-RU')}%`],
      ['Стабильность на начало хода',`${Number(last.stability_at_turn_start_pct).toLocaleString('ru-RU')}%`],
      ['Шаг от пищи',`${Number(last.food_step_pp).toLocaleString('ru-RU')} п.п.`],
      ['Поправка стабильности',`${Number(last.stability_step_pp).toLocaleString('ru-RU')} п.п.`],
      ['Преступность до → после',`${Number(last.crime_rate_at_turn_start_pct).toLocaleString('ru-RU')}% → ${Number(last.crime_rate_after_pct).toLocaleString('ru-RU')}%`],
      ['Фактическое изменение',`${Number(last.crime_change_pp).toLocaleString('ru-RU')} п.п.`],
      ['Развитие / лимит на начало хода',`${last.indicators_at_turn_start?.total_development??'—'} / ${last.indicators_at_turn_start?.development_limit??'—'}`]
      ,...(last.corruption_rate_after_pct==null?[]:[
        ['Нагрузка сверх лимита',`${last.indicators_at_turn_start?.overload??'—'}`],
        ['Коррупция: вклад перегрузки',`${Number(last.corruption_overload_step_pp).toLocaleString('ru-RU',{maximumFractionDigits:5})} п.п.`],
        ['Коррупция: поправка стабильности',`${Number(last.corruption_stability_step_pp).toLocaleString('ru-RU')} п.п.`],
        ['Коррупция до → после',`${Number(last.corruption_rate_at_turn_start_pct).toLocaleString('ru-RU',{maximumFractionDigits:5})}% → ${Number(last.corruption_rate_after_pct).toLocaleString('ru-RU',{maximumFractionDigits:5})}%`],
        ['Изменение коррупции',`${Number(last.corruption_change_pp).toLocaleString('ru-RU',{maximumFractionDigits:5})} п.п.`],
        ['Бонус лояльности высших сословий: начало → следующий ход',`${Number(last.corruption_loyalty_bonus_at_start_pp).toLocaleString('ru-RU')} → ${Number(last.corruption_loyalty_bonus_next_pp).toLocaleString('ru-RU')} п.п.`]
      ]),...(last.net_taxes==null?[]:[
        ['Валовой налог',money(last.gross_taxes)],['Вычет коррупции',money(last.corruption_tax_loss)],['Вычет преступности',money(last.crime_tax_loss)],
        ['Чистый налог',money(last.net_taxes)],['Начислено Казне / сословиям',`${money(last.crown_taxes)} / ${money(last.estate_taxes)}`]
      ])
    ].map(([label,value])=>`<tr><td>${label}</td><td>${escape(value)}</td></tr>`).join('')}</tbody></table></div><p class="hint">Производство, налоги и стабильность рассчитаны с начальными показателями. Новые преступность и коррупция действуют со следующего хода.</p>`}`;
    target.append(condition);
    const estateSummary=document.createElement('section');estateSummary.className='application-panel economy-estate-summary';
    estateSummary.innerHTML=`<h4>Доходы и расходы сословий · прогноз до вложений</h4><p class="hint">Автоматические вложения зависят от остатка после всех начислений и показаны отдельно ниже.</p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Баланс сейчас</th><th>Налоги</th><th>Торговые зоны</th><th>Внутренняя торговля</th><th>Договоры G</th><th>Итого доходы</th><th>Содержание армии</th><th>Колонии</th><th>Платежи по договорам</th><th>Прочие расходы</th><th>Итого расходы</th><th>Сальдо</th></tr></thead><tbody>${buckets.map(name=>{
      const income=estateBudget[name].income,expense=estateBudget[name].expense,saldo=estateBudget[name].saldo;
      return `<tr><td>${name}</td><td>${money(data.buckets?.[name]||0)}</td><td>${money(taxForecast.buckets[name])}</td><td>${money(zoneIncomeByEstate[name]||0)}</td><td>${money(internalTradeForecast.estateIncomeByName?.[name]||0)}</td><td>${money(name==='Корона'?tradeGoldIn:0)}</td><td>${money(income)}</td><td>${money(name==='Корона'?upkeep:sponsorGarrison[name])}</td><td>${money(name==='Корона'?colonyUpkeep:0)}</td><td>${money(name==='Корона'?tradeGoldOut:0)}</td><td>${money(0)}</td><td>${money(expense)}</td><td class="${saldo>0?'balance-positive':saldo<0?'balance-negative':''}">${saldo>0?'+':''}${money(saldo)}</td></tr>`;
    }).join('')}</tbody></table></div>`;
    target.append(estateSummary);
    const investments=document.createElement('section');investments.className='application-panel estate-investment-panel';
    investments.innerHTML=`<h4>Вложения сословий</h4><p class="hint">После расчёта каждого хода сословие может потратить до 20% остатка после резерва на два хода содержания своего гарнизона на развитие. Ключевое сословие ведёт до двух проектов, остальные — один. Цена +1 развития: 1000 + 20 × текущий уровень G. Показанный бюджет рассчитан по текущему балансу; после начислений он может измениться.</p><form data-estate-investments><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Статус</th><th>Баланс</th><th>Доступно сейчас</th><th>Следующая провинция</th><th>Режим</th></tr></thead><tbody>${(investmentData.estates||[]).map(row=>`<tr><td><strong>${escape(row.name)}</strong></td><td>${escape(row.status)}</td><td>${money(row.balance)}</td><td>${money(row.budget)}</td><td>${row.next_province?`${escape(row.next_province.province_name)} · ${money(row.next_province.cost)}`:'Пока недостаточно средств или нет доступной провинции'}</td><td><select data-estate-investment="${escape(row.name)}" aria-label="Вложения: ${escape(row.name)}"><option value="auto" ${row.enabled?'selected':''}>Инвестировать</option><option value="save" ${row.enabled?'':'selected'}>Копить G</option></select></td></tr>`).join('')}</tbody></table></div><button type="submit" class="primary">Сохранить</button><p class="form-message" data-estate-investment-message aria-live="polite"></p></form><h5>Последние вложения</h5><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Ход</th><th>Сословие</th><th>Провинция</th><th>Расход</th><th>Развитие</th></tr></thead><tbody>${(investmentData.events||[]).map(row=>`<tr><td>${Number(row.year)} · ${Number(row.turn)}</td><td>${escape(row.estate)}</td><td>${escape(row.province_name)} · ID ${Number(row.province_id)}</td><td>${money(row.cost)}</td><td>${Number(row.development_before)} → ${Number(row.development_after)}</td></tr>`).join('')||'<tr><td colspan="5">Вложений пока нет.</td></tr>'}</tbody></table></div>`;
    target.append(investments);
    investments.querySelector('[data-estate-investments]').onsubmit=async event=>{event.preventDefault();const form=event.currentTarget,button=form.querySelector('button[type="submit"]'),message=form.querySelector('[data-estate-investment-message]');const enabled=Object.fromEntries([...form.querySelectorAll('[data-estate-investment]')].map(input=>[input.dataset.estateInvestment,input.value==='auto']));button.disabled=true;message.textContent='';try{await estateInvestmentApi('save',stateId,{enabled});showStatus('Политика вложений сохранена',3500);await onRefresh();}catch(error){message.textContent=error.message;button.disabled=false;}};
    const socialNames={Знать:'Празднество',Духовенство:'Церемонии и помощь',Горожане:'Городское мероприятие',Крестьяне:'Общинная помощь'};
    const social=document.createElement('section');social.className='application-panel estate-social-panel';
    social.innerHTML=`<h4>Общественные расходы сословий</h4><p class="hint">Каждое сословие может потратить 2 000 G из своей казны и повысить свою лояльность на 3 п.п. на два хода. Пока поддержка действует, повторная выплата недоступна. По окончании бонус снимается.</p><div class="estate-social-grid">${(investmentData.estates||[]).map(row=>{const active=(socialData.actions||[]).find(action=>action.active&&action.estate===row.name);return `<div class="estate-social-card"><strong>${escape(row.name)}</strong><span>${escape(socialNames[row.name]||'Поддержка')}</span><small>${active?`Действует ещё ${Number(active.turns_remaining)} ход.`:`Баланс: ${money(row.balance)}`}</small><button type="button" data-estate-social="${escape(row.name)}" ${active||Number(row.balance)<2000?'disabled':''}>Провести · 2 000 G</button></div>`;}).join('')}</div><h5>Последние расходы</h5><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Ход</th><th>Сословие</th><th>Расход</th><th>Бонус</th><th>Состояние</th></tr></thead><tbody>${(socialData.actions||[]).map(row=>`<tr><td>${Number(row.year)} · ${Number(row.turn)}</td><td>${escape(row.estate)}</td><td>${money(row.cost)}</td><td>+${Math.round(Number(row.bonus)*100)} п.п.</td><td>${row.active?`Ещё ${Number(row.turns_remaining)} ход.`:'Завершено'}</td></tr>`).join('')||'<tr><td colspan="5">Расходов пока нет.</td></tr>'}</tbody></table></div>`;
    target.append(social);
    social.querySelectorAll('[data-estate-social]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{await estateSocialApi('start',stateId,button.dataset.estateSocial);showStatus('Общественный расход проведён',3500);window.dispatchEvent(new Event('state:resources-changed'));await onRefresh();}catch(error){button.disabled=false;showStatus(error.message,5000);}});
    const fiscal=document.createElement('section');fiscal.className='application-panel estate-fiscal-panel';
    const fiscalEstates=fiscalData.estates||[],wars=fiscalData.wars||[],fiscalEvents=fiscalData.events||[];
    const crownBalance=Number(fiscalData.crown_balance)||0;
    const loyaltyInvestmentCap=row=>Math.floor(Math.max(0,1-Number(row.loyalty||0))*(row.name==='Горожане'||row.name==='Крестьяне'?100:200)+1e-7)*1000;
    const selectedWar=wars[0]?.id;
    fiscal.innerHTML=`<h4>Взносы в казны сословий</h4><p class="hint">Перевод из Казны Короны в казну сословия. За каждые 1 000 G лояльность Горожан и Крестьян растёт на 1 п.п., Знати и Духовенства — на 0,5 п.п. Бонус действует пять лет. Взносы складываются, но лояльность не может превысить 100%.</p><p>Казна Короны: <strong>${money(crownBalance)}</strong></p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Баланс</th><th>Лояльность</th><th>Временный бонус</th><th>Вложить G</th><th></th></tr></thead><tbody>${fiscalEstates.map(row=>{const cap=Math.min(crownBalance,loyaltyInvestmentCap(row));const amountMax=Math.floor(cap/1000)*1000;return `<tr><td>${escape(row.name)}</td><td>${money(row.balance)}</td><td>${(Number(row.loyalty||0)*100).toLocaleString('ru-RU',{maximumFractionDigits:1})}%</td><td>+${(Number(row.investment_bonus||0)*100).toLocaleString('ru-RU',{maximumFractionDigits:2})} п.п.${row.investment_expires_year?` · до ${Number(row.investment_expires_year)} г.`:''}</td><td><input data-fiscal-invest-amount="${escape(row.name)}" type="number" min="1000" step="1000" max="${amountMax}" value="${amountMax>=1000?1000:''}" aria-label="Вклад в казну сословия ${escape(row.name)}" ${amountMax<1000?'disabled':''}></td><td><button type="button" data-fiscal-invest="${escape(row.name)}" ${amountMax<1000?'disabled':''}>Внести</button></td></tr>`;}).join('')}</tbody></table></div><h4>Военный налог</h4><p class="hint">Во время активной войны один раз на сословие в каждой войне в Казну Короны переводится половина его текущего остатка. Лояльность снижается максимум на 20 п.п. и возвращается по 1 п.п. за ход.</p>${wars.length?`<label class="field"><span>Война</span><select data-fiscal-war>${wars.map(war=>`<option value="${Number(war.id)}">Война · государство ID ${Number(war.opponent_id)} · ${escape(war.casus_belli||'')}</option>`).join('')}</select></label><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Текущая казна</th><th>Получит Корона</th><th>Лояльность</th><th></th></tr></thead><tbody>${fiscalEstates.map(row=>{const war=wars.find(item=>Number(item.id)===Number(selectedWar));const used=(war?.used_estates||[]).includes(row.name);return `<tr><td>${escape(row.name)}</td><td>${money(row.balance)}</td><td>${money(Math.round(Number(row.balance)*50)/100)}</td><td>${(Number(row.loyalty||0)*100).toLocaleString('ru-RU',{maximumFractionDigits:1})}%</td><td><button type="button" data-estate-war-tax="${escape(row.name)}" ${used||Number(row.balance)<=0?'disabled':''}>${used?'Уже применён':'Взять налог'}</button></td></tr>`;}).join('')}</tbody></table></div>`:'<p class="hint">Военный налог доступен только во время активной войны.</p>'}<h5>Последние операции</h5><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Ход</th><th>Операция</th><th>Сословие</th><th>G</th><th>Лояльность</th><th>Состояние</th></tr></thead><tbody>${fiscalEvents.map(row=>`<tr><td>${Number(row.year)} · ${Number(row.turn)}</td><td>${row.kind==='loyalty_investment'?'Взнос':'Военный налог'}</td><td>${escape(row.estate)}</td><td>${money(row.amount)}</td><td>${Number(row.loyalty_change)>0?'+':''}${(Number(row.loyalty_change)*100).toLocaleString('ru-RU',{maximumFractionDigits:2})} п.п.</td><td>${row.kind==='loyalty_investment'?(row.active?`До ${Number(row.expires_year)} г.`:'Истёк'):row.recovery_remaining>0?`Восстановить ${Number(row.recovery_remaining*100).toLocaleString('ru-RU',{maximumFractionDigits:1})} п.п.`:'Лояльность восстановлена'}</td></tr>`).join('')||'<tr><td colspan="6">Операций пока нет.</td></tr>'}</tbody></table></div>`;
    target.append(fiscal);
    fiscal.querySelectorAll('[data-fiscal-invest]').forEach(button=>button.onclick=async()=>{const estate=button.dataset.fiscalInvest,input=fiscal.querySelector(`[data-fiscal-invest-amount="${CSS.escape(estate)}"]`),amount=Number(input?.value);button.disabled=true;try{await estateFiscalApi('invest',stateId,{estate,amount});showStatus('Вклад перечислен, бонус лояльности активирован',4500);window.dispatchEvent(new Event('state:resources-changed'));await onRefresh();}catch(error){button.disabled=false;showStatus(error.message,5500);}});
    const fiscalWarSelect=fiscal.querySelector('[data-fiscal-war]');
    const syncFiscalWar=()=>{const war=wars.find(item=>Number(item.id)===Number(fiscalWarSelect?.value));fiscal.querySelectorAll('[data-estate-war-tax]').forEach(button=>{const used=(war?.used_estates||[]).includes(button.dataset.estateWarTax);button.disabled=used||Number(fiscalEstates.find(row=>row.name===button.dataset.estateWarTax)?.balance||0)<=0;button.textContent=used?'Уже применён':'Взять налог';});};
    fiscalWarSelect?.addEventListener('change',syncFiscalWar);syncFiscalWar();
    fiscal.querySelectorAll('[data-estate-war-tax]').forEach(button=>button.onclick=async()=>{const warId=Number(fiscalWarSelect?.value);if(!warId)return;button.disabled=true;try{await estateFiscalApi('military_tax',stateId,{estate:button.dataset.estateWarTax,war_id:warId});showStatus('Военный налог перечислен; восстановление лояльности началось',4500);window.dispatchEvent(new Event('state:resources-changed'));await onRefresh();}catch(error){button.disabled=false;showStatus(error.message,5500);}});
    if(isAdmin)bindTestTurn(host,test,onRefresh);
  }catch(error){if(target.isConnected)target.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

async function loadStateFinances(host,stateId,isAdmin){
  const target=host.querySelector('[data-state-finances]');if(!target)return;
  try{
    const data=await api(`${isAdmin?'admin':'my'}/states/${stateId}/tax-rates`);if(!target.isConnected)return;
    target.innerHTML=`<section class="state-dashboard-card"><h4>Казна</h4><strong class="state-finance-total">${Number(data.buckets?.Корона||0).toLocaleString('ru-RU')} G</strong></section><section class="state-dashboard-card"><h4>Престиж</h4><strong class="state-finance-total">${Number(data.prestige||0).toLocaleString('ru-RU')} ОП</strong></section>`;
    if(Number(user?.state_ids?.[0])===Number(stateId)){$('header-treasury').textContent=Number(data.buckets?.Корона||0).toLocaleString('ru-RU');$('header-prestige').textContent=Number(data.prestige||0).toLocaleString('ru-RU');}
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
    const [data,tradeData,proposalData]=await Promise.all([api('my/marriage-offers'),api('my/trade-agreements'),api('my/diplomatic-proposals')]);
    if(!host.isConnected)return;
    const contextStateId=stateId||Number(data.states?.[0]?.id)||null;
    const militarySnapshot=contextStateId?await militaryApi('snapshot',contextStateId).catch(()=>null):null;
    const states=(categories||[]).filter(row=>row.layer==='states').map(row=>({id:Number(row.id),name:row.name,color:row.color}));
    const relationRows=militarySnapshot?.states||[];
    const relationFor=id=>{const war=relationRows.find(row=>Number(row.id)===Number(id));if(war?.relation?.includes('war'))return 'Война';const agreements=(tradeData.agreements||[]).filter(row=>[Number(row.from_state_id),Number(row.to_state_id)].includes(Number(id))&&row.status==='accepted');if(agreements.length)return 'Торговый договор';const passage=militarySnapshot?.diplomacy?.find(row=>row.kind==='passage'&&row.status==='accepted'&&[Number(row.from_state_id),Number(row.to_state_id)].includes(Number(id)));if(passage)return 'Право прохода';const marriage=(data.incoming||[]).concat(data.outgoing||[]).some(row=>[Number(row.from_state_id),Number(row.to_state_id)].includes(Number(id))&&row.status==='accepted');return marriage?'Династический брак':'Нейтрально';};
    const stateRowsHtml=states.filter(row=>row.id!==contextStateId).map(row=>`<button type="button" class="diplomacy-state-row" data-diplomacy-state="${row.id}"><span class="diplomacy-flag" data-state-flag="${row.id}" style="--state-color:${escape(row.color)}"></span><span class="diplomacy-state-name">${escape(row.name)}</span><span class="badge">${escape(relationFor(row.id))}</span></button>`).join('');
    const multilateralCards=(proposalData.proposals||[]).map(proposal=>`<article class="application-panel diplomacy-proposal-card"><header><strong>${escape(proposal.title)}</strong><span class="badge">${escape({pending:'Ожидает ответов',active:'Действует',rejected:'Отклонено',cancelled:'Отозвано',ended:'Завершено'}[proposal.status]||proposal.status)}</span></header><p class="hint">Инициатор: ${escape(proposal.proposer_state)}</p><p>${escape(proposal.terms)}</p><div class="diplomacy-participants">${(proposal.participants||[]).map(item=>`<span>${escape(item.state_name)} · ${escape({pending:'ожидает',accepted:'принято',rejected:'отклонено'}[item.decision]||item.decision)}</span>`).join('')}</div>${proposal.status==='pending'?(proposal.participants||[]).filter(item=>item.decision==='pending'&&(user.role==='admin'||(data.states||[]).some(s=>Number(s.id)===Number(item.state_id)))).map(item=>`<button type="button" data-proposal-action="accept" data-proposal-id="${Number(proposal.id)}" data-proposal-state="${Number(item.state_id)}">Принять от имени ${escape(item.state_name)}</button><button type="button" class="danger-button" data-proposal-action="reject" data-proposal-id="${Number(proposal.id)}" data-proposal-state="${Number(item.state_id)}">Отклонить</button>`).join(''):''}${proposal.status==='active'?`<button type="button" class="danger-button" data-proposal-action="end" data-proposal-id="${Number(proposal.id)}">Завершить договор</button>`:''}${proposal.status==='pending'&&Number(proposal.proposer_state_id)===contextStateId?`<button type="button" class="danger-button" data-proposal-action="cancel" data-proposal-id="${Number(proposal.id)}">Отозвать предложение</button>`:''}</article>`).join('');
    const multiCreate=(states.length>=3&&(user.role==='admin'||data.states?.length)?`<form class="application-panel diplomacy-multilateral-form"><h4>Новое многостороннее предложение</h4>${isAdminState?`<input type="hidden" name="proposer_state_id" value="${stateId}">`:user.role==='admin'?`<label class="field"><span>От имени государства</span><select name="proposer_state_id" required>${states.map(row=>`<option value="${row.id}">${escape(row.name)}</option>`).join('')}</select></label>`:''}<label class="field"><span>Название</span><input name="title" maxlength="160" required></label><label class="field"><span>Условия договора</span><textarea name="terms" rows="4" maxlength="10000" required></textarea></label><fieldset class="diplomacy-participant-picker"><legend>Участники (выберите минимум два)</legend>${states.filter(row=>row.id!==contextStateId).map(row=>`<label><input type="checkbox" name="participant_state_ids" value="${row.id}"><span>${escape(row.name)}</span></label>`).join('')}</fieldset><button class="primary" type="submit">Отправить текстовое предложение</button></form>`:'<p class="hint">Для предложения нужен доступ хотя бы к одному государству.</p>');
    const participantLabel=person=>`${person.name} ${person.surname||''} · ${person.age} лет · ${person.gender} · ${person.race}`.trim();
    const sendForm=!isAdminState&&data.states.length&&data.targets.length?`<form class="dynastic-offer-form stack"><label class="field"><span>От имени государства</span><select name="from_state" required>${data.states.map(state=>`<option value="${Number(state.id)}">${escape(state.name)} · ${escape(state.authority||'Форма власти не задана')}</option>`).join('')}</select></label><label class="field"><span>Государство-получатель</span><select name="to_state" required></select></label><label class="field"><span>Персонаж вашего государства</span><select name="from_character" required></select></label><label class="field"><span>Персонаж государства-получателя (противоположный пол)</span><select name="to_character" required></select></label><div class="marriage-warning" data-marriage-warning role="status">Выберите персонажей, чтобы увидеть последствия договора.</div><button class="primary" type="submit">Отправить предложение</button></form>`:'<p class="hint">Предложения династического брака создаются игроками государств.</p>';
    const statusLabel=status=>({pending:'Ожидает ответа',accepted:'Заключён',declined:'Отклонён',rejected:'Отклонён',cancelled:'Отозван',ended:'Расторгнут',active:'Действует',awaiting_admin:'Ожидает решения администратора'}[status]||status||'Статус неизвестен');
    const proposalCard=(proposal,incoming)=>`<article class="application-panel marriage-candidate"><strong>Династический брак · ${escape(proposal.from_state)} → ${escape(proposal.to_state)}</strong><span>${escape(statusLabel(proposal.status))}</span><span>${escape(proposal.from_ruler)} ↔ ${escape(proposal.to_ruler)}</span><p class="hint">Законность детей: ${proposal.lawful_for_children?'дети будут законными наследниками в государстве матери-Династии и войдут в её семейный реестр':'брак не даёт детям законного права на наследование'}. Зачатие: ${proposal.child_race&&Number(proposal.from_age)<(proposal.from_gender==='Мужской'?60:45)&&Number(proposal.to_age)<(proposal.to_gender==='Мужской'?60:45)?`возможно, раса ребёнка — ${escape(proposal.child_race)}`:'невозможно по возрасту или сочетаемости рас'}.</p><small>${new Date(proposal.created_at).toLocaleDateString('ru-RU')}</small>${incoming&&proposal.status==='pending'?`<div class="inline-actions"><button type="button" data-marriage-decision="accept" data-proposal-id="${Number(proposal.id)}">Принять</button><button type="button" class="danger-button" data-marriage-decision="reject" data-proposal-id="${Number(proposal.id)}">Отклонить</button></div>`:''}</article>`;
    const relevant=item=>!stateId||Number(item.from_state_id)===stateId||Number(item.to_state_id)===stateId;
    const marriageRecords=(data.incoming||[]).map(item=>({...item,contractType:'marriage',incoming:Number(item.to_state_id)===stateId||(!stateId&&user.role!=='admin')}));
    const marriageIncoming=isAdminState?marriageRecords.filter(item=>Number(item.to_state_id)===stateId):((data.incoming||[]).map(item=>({...item,contractType:'marriage',incoming:true})));
    const marriageOutgoing=isAdminState?marriageRecords.filter(item=>Number(item.from_state_id)===stateId):((data.outgoing||[]).map(item=>({...item,contractType:'marriage',incoming:false})));
    const tradeRecords=(tradeData.agreements||[]).filter(relevant).map(item=>({...item,contractType:'trade'}));
    const tradeIncoming=tradeRecords.filter(item=>Number(item.to_state_id)===stateId||(!stateId&&item.incoming));
    const tradeOutgoing=tradeRecords.filter(item=>Number(item.from_state_id)===stateId||(!stateId&&!item.incoming));
    const tradeCard=(item,incoming)=>`<article class="application-panel marriage-candidate"><strong>Торговый договор · ${escape(item.from_state)} → ${escape(item.to_state)}</strong><span>${escape(statusLabel(item.status))}</span><p>Маршрут: ${tradeRouteNames(item.route_province_ids||[])}</p><p>Отправитель: ${tradeTermsText(item.terms?.from_goods,item.terms?.from_gold)}</p><p>Получатель: ${tradeTermsText(item.terms?.to_goods,item.terms?.to_gold)}</p><small>${Number(item.created_year)} год · ${Number(item.created_turn)} ход</small>${item.status==='pending'&&incoming?`<div class="inline-actions"><button type="button" data-trade-action="accept" data-trade-id="${Number(item.id)}">Принять</button><button type="button" class="danger-button" data-trade-action="decline" data-trade-id="${Number(item.id)}">Отклонить</button></div>`:''}${['pending','accepted'].includes(item.status)&&(!incoming||user.role==='admin')?`<div class="inline-actions"><button type="button" class="danger-button" data-trade-action="cancel" data-trade-id="${Number(item.id)}">Отозвать / расторгнуть</button></div>`:''}</article>`;
    const incoming=[...marriageIncoming,...tradeIncoming].sort((a,b)=>String(b.created_at||'').localeCompare(String(a.created_at||'')));
    const outgoing=[...marriageOutgoing,...tradeOutgoing].sort((a,b)=>String(b.created_at||'').localeCompare(String(a.created_at||'')));
    const outgoingRows=outgoing.map(item=>`<tr><td>${escape(item.to_state||'—')}</td><td>${item.contractType==='trade'?'Торговый договор':'Династический брак'}</td><td>${escape(statusLabel(item.status))}</td></tr>`).join('');
    host.innerHTML=`<div class="state-menu stack diplomacy-page"><h3>Дипломатия</h3><nav class="diplomacy-tabs" aria-label="Разделы дипломатии"><button type="button" class="active" data-diplomacy-tab="countries" aria-selected="true">Государства</button><button type="button" data-diplomacy-tab="summary" aria-selected="false">Дипломатическая сводка</button></nav><section class="diplomacy-view" data-diplomacy-view="countries"><div class="diplomacy-state-list">${stateRowsHtml||'<p class="hint">Нет других государств для отображения.</p>'}</div></section><section class="diplomacy-view" data-diplomacy-view="summary" hidden><h4>Договоры и дипломатические состояния</h4><div class="diplomacy-existing"><section class="application-panel"><h4>Предложить договор</h4><label class="field"><span>Тип договора</span><select data-contract-type><option value="dynastic_marriage" ${activeContractType==='dynastic_marriage'?'selected':''}>Династический брак</option><option value="trade" ${activeContractType==='trade'?'selected':''}>Торговый договор</option></select></label><div data-contract-panel="dynastic_marriage" ${activeContractType==='dynastic_marriage'?'':'hidden'}>${sendForm}</div><div data-contract-panel="trade" ${activeContractType==='trade'?'':'hidden'}><div data-trade-proposal></div></div></section><section class="application-panel"><h4>Входящие договоры</h4>${incoming.length?`<div class="marriage-candidates">${incoming.map(item=>item.contractType==='marriage'?proposalCard(item,true):tradeCard(item,true)).join('')}</div>`:'<p class="hint">Входящих договоров нет.</p>'}</section><section class="application-panel"><h4>Отправленные договоры</h4>${outgoing.length?`<div class="table-scroll"><table class="state-data-table diplomacy-contract-table"><thead><tr><th>Государство</th><th>Тип договора</th><th>Статус договора</th></tr></thead><tbody>${outgoingRows}</tbody></table></div>`:'<p class="hint">Отправленных договоров нет.</p>'}</section><section class="application-panel"><h4>Многосторонние договоры</h4>${multiCreate}${multilateralCards||'<p class="hint">Договоров пока нет.</p>'}</section></div></section><dialog class="diplomacy-dialog"><div class="modal-shell surface"><header><strong data-diplomacy-modal-title></strong><button type="button" class="icon-button" data-diplomacy-close aria-label="Закрыть">×</button></header><div class="diplomacy-modal-content" data-diplomacy-modal-content></div></div></dialog></div>`;
    hydrateDiplomacyFlags(host);
    const contractSelect=host.querySelector('[data-contract-type]');
    const contractSection=contractSelect?.closest('section');
    for(const [kind,label] of [['war','Объявить войну'],['peace','Заключить мир'],['passage','Право прохода']]){
      contractSelect.add(new Option(label,kind));
      const panel=document.createElement('div');panel.dataset.contractPanel=kind;panel.hidden=activeContractType!==kind;
      panel.innerHTML='<p class="hint">Загружаю форму…</p>';contractSection.append(panel);
    }
    if(['war','peace','passage'].includes(activeContractType)){
      contractSelect.value=activeContractType;
      host.querySelectorAll('[data-contract-panel]').forEach(panel=>{panel.hidden=panel.dataset.contractPanel!==activeContractType;});
    }
    const militaryRelations=document.createElement('div');militaryRelations.className='diplomacy-military';host.querySelector('[data-diplomacy-view="summary"] .diplomacy-existing').append(militaryRelations);
    void renderMilitaryDiplomacy(militaryRelations,{stateId,notify:message=>showStatus(message,4000)});
    const showMilitaryContract=kind=>{if(['war','peace','passage'].includes(kind))void renderMilitaryContract(host.querySelector(`[data-contract-panel="${kind}"]`),kind,{stateId,notify:message=>showStatus(message,4000)}).catch(error=>showStatus(error.message,4000));};
    showMilitaryContract(activeContractType);
    contractSelect.addEventListener('change',event=>showMilitaryContract(event.target.value));
    const diplomacyPanels=[...host.querySelector('.state-menu').children].filter(node=>node.classList.contains('application-panel'));
    if(diplomacyPanels.length===3)diplomacyPanels[2].after(diplomacyPanels[0]);
    const tradeHost=host.querySelector('[data-trade-proposal]');
    void renderTradeProposal(tradeHost,{stateId});
    host.querySelector('[data-contract-type]')?.addEventListener('change',event=>{
      activeContractType=event.target.value;
      host.querySelectorAll('[data-contract-panel]').forEach(panel=>{panel.hidden=panel.dataset.contractPanel!==event.target.value;});
    });
    host.querySelectorAll('[data-diplomacy-tab]').forEach(button=>button.addEventListener('click',()=>{
      host.querySelectorAll('[data-diplomacy-tab]').forEach(tab=>{const active=tab===button;tab.classList.toggle('active',active);tab.setAttribute('aria-selected',String(active));});
      host.querySelectorAll('[data-diplomacy-view]').forEach(view=>{view.hidden=view.dataset.diplomacyView!==button.dataset.diplomacyTab;});
    }));
    const modal=host.querySelector('.diplomacy-dialog'),modalContent=host.querySelector('[data-diplomacy-modal-content]');
    const openCountry=country=>{
      if(!country)return;host.querySelector('[data-diplomacy-modal-title]').textContent=country.name;
      const id=Number(country.id),relationship=relationFor(id);
      const contracts=(tradeData.agreements||[]).filter(row=>[Number(row.from_state_id),Number(row.to_state_id)].includes(id)).map(row=>{const incoming=Number(row.to_state_id)===id;const actions=row.status==='pending'&&incoming?`<button type="button" data-modal-agreement="trade" data-modal-id="${Number(row.id)}" data-modal-action="accept">Принять</button><button type="button" class="danger-button" data-modal-agreement="trade" data-modal-id="${Number(row.id)}" data-modal-action="decline">Отклонить</button>`:['pending','accepted'].includes(row.status)&&(!incoming||user.role==='admin')?`<button type="button" class="danger-button" data-modal-agreement="trade" data-modal-id="${Number(row.id)}" data-modal-action="cancel">Отозвать / расторгнуть</button>`:'';return `<li>Торговый договор · ${escape({pending:'ожидает ответа',accepted:'действует',declined:'отклонён',cancelled:'завершён'}[row.status]||row.status)} ${actions?`<div class="inline-actions">${actions}</div>`:''}</li>`;});
      for(const row of [...(data.incoming||[]),...(data.outgoing||[])])if([Number(row.from_state_id),Number(row.to_state_id)].includes(id)){const incoming=Number(row.to_state_id)===id,actions=row.status==='pending'&&incoming?`<button type="button" data-modal-agreement="marriage" data-modal-id="${Number(row.id)}" data-modal-action="accept">Принять</button><button type="button" class="danger-button" data-modal-agreement="marriage" data-modal-id="${Number(row.id)}" data-modal-action="reject">Отклонить</button>`:'';contracts.push(`<li>Династический брак · ${escape({pending:'ожидает ответа',accepted:'заключён',declined:'отклонён',cancelled:'отозван'}[row.status]||row.status)} ${actions?`<div class="inline-actions">${actions}</div>`:''}</li>`);}
      for(const row of militarySnapshot?.diplomacy||[])if([Number(row.from_state_id),Number(row.to_state_id)].includes(id))contracts.push(`<li>${escape({passage:'Право прохода',peace:'Мирный договор',war:'Военное действие'}[row.kind]||row.kind)} · ${escape(({pending:'Ожидает ответа',awaiting_admin:'На рассмотрении администратора',accepted:'Действует',rejected:'Отклонено',ended:'Расторгнуто'})[row.status]||statusLabel(row.status))}</li>`);
      for(const row of proposalData.proposals||[])if((row.participants||[]).some(item=>Number(item.state_id)===id))contracts.push(`<li>${escape(row.title)} · ${escape({pending:'ожидает ответов',active:'действует',rejected:'отклонено',cancelled:'отозвано',ended:'завершено'}[row.status]||row.status)}</li>`);
      modalContent.innerHTML=`<div class="diplomacy-country-summary"><span class="diplomacy-flag large" data-state-flag="${id}" style="--state-color:${escape(country.color||'#6b7464')}"></span><div><strong>${escape(country.name)}</strong><span class="badge">${escape(relationship)}</span></div></div><section class="application-panel"><h4>Текущие договоры и отношения</h4>${contracts.length?`<ul>${contracts.join('')}</ul>`:`<p class="hint">Активных договоров не найдено.</p>`}</section><section class="application-panel"><h4>Дипломатические действия</h4><div class="diplomacy-actions"><button type="button" data-contract-jump="trade">Предложить торговый договор</button><button type="button" data-contract-jump="passage">Предложить право прохода</button>${!isAdminState?'<button type="button" data-contract-jump="dynastic_marriage">Предложить династический брак</button>':''}</div></section>`;
      hydrateDiplomacyFlags(modalContent);
      modalContent.querySelectorAll('[data-modal-agreement]').forEach(action=>action.addEventListener('click',async()=>{action.disabled=true;try{const prefix=user.role==='admin'?'admin':'my',kind=action.dataset.modalAgreement,route=kind==='trade'?`${prefix}/trade-agreements/${Number(action.dataset.modalId)}/${action.dataset.modalAction}`:`${prefix}/marriage-offers/${Number(action.dataset.modalId)}/${action.dataset.modalAction}`;await api(route,{method:'POST',body:'{}'});showStatus('Статус договора обновлён',3500);void renderDynasticDiplomacy(host,options);}catch(error){action.disabled=false;showStatus(error.message,5000);}}));
      modalContent.querySelectorAll('[data-contract-jump]').forEach(action=>action.addEventListener('click',()=>{
        const kind=action.dataset.contractJump;modal.close();host.querySelector('[data-diplomacy-tab="summary"]').click();
        activeContractType=kind;const selector=host.querySelector('[data-contract-type]');if(selector){selector.value=kind;selector.dispatchEvent(new Event('change',{bubbles:true}));}
        const target=kind==='dynastic_marriage'?host.querySelector('.dynastic-offer-form select[name="to_state"]'):kind==='trade'?host.querySelector('.trade-agreement-form select[name="to_state"]'):host.querySelector('[data-contract-panel="passage"] select[name="to_state_id"]');
        if(target){target.value=String(id);target.dispatchEvent(new Event('change',{bubbles:true}));}
      }));
      if(typeof modal.showModal==='function')modal.showModal();
    };
    host.querySelectorAll('[data-diplomacy-state]').forEach(button=>button.addEventListener('click',()=>openCountry(states.find(row=>row.id===Number(button.dataset.diplomacyState)))));
    host.querySelector('[data-diplomacy-close]')?.addEventListener('click',()=>modal.close());
    modal?.addEventListener('click',event=>{if(event.target===modal)modal.close();});
    const multiForm=host.querySelector('.diplomacy-multilateral-form');
    if(multiForm?.elements.proposer_state_id?.tagName==='SELECT'){
      const syncInitiator=()=>multiForm.querySelectorAll('[name="participant_state_ids"]').forEach(input=>{input.disabled=Number(input.value)===Number(multiForm.elements.proposer_state_id.value);if(input.disabled)input.checked=false;});
      multiForm.elements.proposer_state_id.addEventListener('change',syncInitiator);syncInitiator();
    }
    multiForm?.addEventListener('submit',async event=>{event.preventDefault();const form=event.currentTarget,button=form.querySelector('[type="submit"]'),participants=[...form.querySelectorAll('[name="participant_state_ids"]:checked')].map(input=>Number(input.value));if(participants.length<2){showStatus('Выберите как минимум два других государства',3500);return;}button.disabled=true;try{const payload={title:form.elements.title.value,terms:form.elements.terms.value,participant_state_ids:participants};if(form.elements.proposer_state_id)payload.proposer_state_id=Number(form.elements.proposer_state_id.value);await api('my/diplomatic-proposals',{method:'POST',body:JSON.stringify(payload)});showStatus('Текстовое предложение отправлено участникам',4000);void renderDynasticDiplomacy(host,options);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
    host.querySelectorAll('[data-proposal-action]').forEach(button=>button.addEventListener('click',async()=>{button.disabled=true;try{const result=await api(`my/diplomatic-proposals/${Number(button.dataset.proposalId)}/${button.dataset.proposalAction}`,{method:'POST',body:JSON.stringify({state_id:Number(button.dataset.proposalState)||undefined})});showStatus(result.status==='active'?'Договор принят всеми участниками и действует как текстовая запись':'Ответ сохранён',4000);void renderDynasticDiplomacy(host,options);}catch(error){button.disabled=false;showStatus(error.message,5000);}}));
    if(pendingDiplomacyStateId){const country=states.find(row=>row.id===Number(pendingDiplomacyStateId));pendingDiplomacyStateId=null;if(country)openCountry(country);}
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
    host.querySelectorAll('[data-trade-action]').forEach(button=>button.addEventListener('click',async()=>{button.disabled=true;try{const prefix=user.role==='admin'?'admin':'my';const result=await api(`${prefix}/trade-agreements/${Number(button.dataset.tradeId)}/${button.dataset.tradeAction}`,{method:'POST',body:'{}'});showStatus(result.status==='accepted'?'Договор согласован':'Статус договора обновлён',4000);renderDynasticDiplomacy(host,options);}catch(error){button.disabled=false;showStatus(error.message,5000);}}));
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
    host.innerHTML=form;
    const tradeForm=host.querySelector('.trade-agreement-form');if(!tradeForm)return;
    const refreshAvailability=async side=>{const stateId=Number(tradeForm.elements[side==='from'?'from_state':'to_state'].value);try{await loadTradeAvailability(stateId);}catch(error){showStatus(error.message,5000);}if(!tradeForm.isConnected)return;for(const row of tradeForm.querySelectorAll(`[data-trade-side="${side}"] .trade-good-row`)){const name=row.querySelector('select').value,note=row.querySelector('[data-available-note]'),input=row.querySelector('input');const qty=name?tradeAvailable(data,stateId,name):0;note.textContent=name?`Доступно: ${qty.toLocaleString('ru-RU')}`:'Выберите ресурс';input.max=String(qty);}};
    tradeForm.addEventListener('change',event=>{if(event.target.name==='from_state'||event.target.name==='to_state'){tradeProposalDraft.route=[];window.dispatchEvent(new CustomEvent('trade:route-pick',{detail:{active:false,clear:true}}));tradeForm.querySelector('.trade-route-preview')?.remove();const placeholder=tradeForm.querySelector('[data-trade-route-placeholder]');if(!placeholder){const note=document.createElement('p');note.className='hint';note.dataset.tradeRoutePlaceholder='';note.textContent='Маршрут ещё не выбран.';tradeForm.querySelector('.trade-route-controls')?.append(note);}const status=tradeForm.querySelector('[data-trade-route-status]');if(status)status.textContent='Выберите города и промежуточные провинции кликами на карте.';void refreshAvailability(event.target.name==='from_state'?'from':'to');}else if(event.target.matches('.trade-good-row select')){const row=event.target.closest('.trade-good-row'),name=event.target.value,side=row.closest('.trade-goods-list').dataset.tradeSide,stateId=Number(tradeForm.elements[side==='from'?'from_state':'to_state'].value);const duplicates=[...row.closest('.trade-goods-list').querySelectorAll('.trade-good-row select')].filter(select=>select.value===name);if(name&&duplicates.length>1){event.target.value='';showStatus('Каждый ресурс можно добавить только один раз на сторону договора.',3500);}const selectedName=event.target.value;row.querySelector('[data-available-note]').textContent=selectedName?`Доступно: ${tradeAvailable(data,stateId,selectedName).toLocaleString('ru-RU')}`:'Выберите ресурс';row.querySelector('input').max=String(tradeAvailable(data,stateId,selectedName));}syncTradeDraft(tradeForm);});
    tradeForm.addEventListener('input',()=>syncTradeDraft(tradeForm));
    tradeForm.querySelectorAll('[data-trade-add]').forEach(button=>button.onclick=()=>{syncTradeDraft(tradeForm);tradeProposalDraft[`${button.dataset.tradeAdd}Goods`].push({name:'',quantity:0});void renderTradeProposal(host,options);});
    tradeForm.querySelectorAll('[data-trade-remove]').forEach(button=>button.onclick=()=>{const side=button.closest('.trade-goods-list').dataset.tradeSide;syncTradeDraft(tradeForm);tradeProposalDraft[`${side}Goods`].splice([...button.closest('.trade-goods-list').querySelectorAll('.trade-good-row')].indexOf(button.closest('.trade-good-row')),1);void renderTradeProposal(host,options);});
    void refreshAvailability('from');void refreshAvailability('to');
    tradeForm.querySelector('[data-trade-pick-route]').onclick=()=>{syncTradeDraft(tradeForm);tradeProposalDraft.route=[];activeContractType='trade';tradeRoutePick={fromStateId:Number(tradeForm.elements.from_state.value),toStateId:Number(tradeForm.elements.to_state.value),adminStateId:stateId,ids:[]};showMap();window.dispatchEvent(new CustomEvent('trade:route-pick',{detail:{active:true}}));showStatus('Выберите на карте начальный город, маршрут по соседним провинциям и город получателя. Esc — отмена.',0);};
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
async function renderTradeDashboard(host,stateId,productionRows=[],stateName=''){
  host.innerHTML='<p class="hint">Загружаю торговлю…</p>';
  try{
    const prefix=user?.role==='admin'?'admin':'my';
    const [overview,agreements,settlements,duty,transit]=await Promise.all([
      api(`${prefix}/states/${stateId}/trade-overview`),api('my/trade-agreements'),
      api('my/trade-settlements'),api(`${prefix}/states/${stateId}/trade-duty`),
      api(`${prefix}/states/${stateId}/transit-tolls`)
    ]);
    if(!host.isConnected)return;
    const money=value=>`${Number(value||0).toLocaleString('ru-RU')} G`;
    const unitPrice=value=>`${Number(value||0).toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})} G`;
    const priceTrend=value=>value==='up'?'<span class="price-trend-up" title="Ожидается рост цены" aria-label="Ожидается рост цены">↑</span>':value==='down'?'<span class="price-trend-down" title="Ожидается снижение цены" aria-label="Ожидается снижение цены">↓</span>':'<span class="price-trend-stable" title="Цена почти не изменится" aria-label="Цена почти не изменится">→</span>';
    const qty=value=>Number(value||0).toLocaleString('ru-RU',{maximumFractionDigits:2});
    const table=(headers,rows,empty)=>rows.length?`<div class="table-scroll"><table class="state-data-table"><thead><tr>${headers.map(h=>`<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`:`<p class="hint">${empty}</p>`;
    const previousStatePrices=new Map((overview.resources||[]).map(row=>[row.resource_name,Number(row.dynamic_price)]));
    const forecastResources=calculateInternalTradeForecast(productionRows,Number(duty.rate)||15,previousStatePrices).resources;
    const displayResources=forecastResources;
    const resourceRows=displayResources.map(row=>`<tr><td>${escape(row.resource_name)}</td><td>${qty(row.production)}</td><td>${qty(row.consumption)}</td><td class="${Number(row.balance)>0?'balance-positive':Number(row.balance)<0?'balance-negative':''}">${qty(row.balance??(Number(row.production||0)-Number(row.consumption||0)))}</td><td>${money(row.base_price)}</td><td>${unitPrice(row.dynamic_price)}</td><td>${priceTrend(row.price_trend)}</td><td>${qty(row.contract_import)} / ${qty(row.zone_import)}</td><td>${qty(row.contract_export)} / ${qty(row.zone_export)}</td><td>${money(row.duty_income)}</td></tr>`);
    const ownAgreements=(agreements.agreements||[]).filter(a=>Number(a.from_state_id)===stateId||Number(a.to_state_id)===stateId);
    const agreementRows=ownAgreements.map(a=>`<tr><td>${escape(a.from_state)} → ${escape(a.to_state)}</td><td>${escape(a.status==='accepted'?'Действует':a.status==='pending'?'Ожидает':'Завершён')}</td><td>${tradeTermsText(a.terms?.from_goods,a.terms?.from_gold)}</td><td>${tradeTermsText(a.terms?.to_goods,a.terms?.to_gold)}</td><td>${tradeRouteNames(a.route_province_ids||[])}</td></tr>`);
    const transitRows=(settlements.lines||[]).filter(line=>(line.transit_fees||[]).some(f=>Number(f.state_id)===stateId)).map(line=>{
      const fee=(line.transit_fees||[]).find(f=>Number(f.state_id)===stateId);
      return `<tr><td>${Number(line.year)} · ${Number(line.turn)}</td><td>${escape(line.sender)} → ${escape(line.recipient)}</td><td>${escape(line.item_name||'G')}</td><td>${qty(line.sent)}</td><td>${money(fee?.amount)}</td></tr>`;
    });
    const previousZonePrices=new Map((overview.zones||[]).map(zone=>[Number(zone.id),new Map((zone.resources||[]).map(row=>[row.resource_name,Number(row.dynamic_price)]))]));
    const forecastZones=calculateTradeZoneForecast(allProvinces,previousZonePrices);
    const activeStateName=stateName||allProvinces.find(p=>Number(p.layers?.states?.id)===stateId)?.layers?.states?.name||'';
    const visibleZones=forecastZones.filter(zone=>(zone.participants||[]).some(participant=>participant.state_name===activeStateName));
    const zoneTabs=visibleZones.map((zone,index)=>`<button type="button" role="tab" data-trade-panel="zone-${Number(zone.id)}" aria-selected="false">${escape(zone.name||`Торговая зона №${index+1}`)}</button>`).join('');
    const zonePanels=visibleZones.map(zone=>{
      const resourceRows=(zone.resources||[]).map(r=>{const balance=Number(r.local_supply||0)+Number(r.incoming||0)-Number(r.demand||0);return `<tr><td>${escape(r.resource_name)}</td><td>${qty(r.local_supply)}</td><td>${qty(r.demand)}</td><td class="${balance>0?'balance-positive':balance<0?'balance-negative':''}">${qty(balance)}</td><td>${qty(r.incoming)}</td><td>${unitPrice(r.dynamic_price)}</td><td>${priceTrend(r.price_trend)}</td><td>${money(r.local_turnover)}</td><td>${money(r.incoming_turnover)}</td></tr>`;});
      const participants=(zone.participants||[]).map(p=>`<tr><td>${escape(p.state_name)}</td><td>${qty(p.influence)}</td><td>${(Number(p.share||0)*100).toLocaleString('ru-RU',{maximumFractionDigits:1})}%</td><td>${money(p.local_income)}</td><td>${money(p.export_income)}</td><td><strong>${money(Number(p.local_income||0)+Number(p.export_income||0))}</strong></td></tr>`);
      return `<section data-trade-view="zone-${Number(zone.id)}" hidden><h4>${escape(zone.name)}</h4><p class="hint">Прогноз следующего хода по провинциям, контролируемым государствами. Баланс = выпуск + ввоз − потребление. Доход участника = оборот зоны × его доля торгового влияния.</p>${table(['Ресурс','Местное производство','Потребление','Баланс','Ввоз из других зон','Цена зоны','Тенденция','Внутренний оборот','Оборот ввоза'],resourceRows,'У контролируемых провинций зоны пока нет ресурсных показателей.')}${table(['Государство','Влияние','Доля дохода','Прибыль зоны','Прибыль вывоза','Всего прибыль'],participants,'Государств с торговым влиянием в зоне пока нет.')}</section>`;
    }).join('');
    const flows=(overview.flows||[]).map(f=>`<tr><td>${escape(f.from_zone)} → ${escape(f.to_zone)}</td><td>${escape(f.resource_name)}</td><td>${escape(f.seller)} → ${escape(f.buyer)}</td><td>${qty(f.quantity)}</td><td>${money(f.unit_price)}</td><td>${money(f.amount)}</td><td>${qty(f.distance)} пров.</td></tr>`);
    host.innerHTML=`<div class="trade-dashboard"><div class="trade-subtabs" role="tablist" aria-label="Разделы торговли"><button type="button" role="tab" data-trade-panel="internal" aria-selected="true">Внутренняя торговля</button>${zoneTabs}<button type="button" role="tab" data-trade-panel="flows" aria-selected="false">Межрыночные потоки</button></div>
      <section data-trade-view="internal"><div class="trade-top-cards"><form class="application-panel trade-duty-form"><h4>Внутренняя пошлина</h4><label class="field"><span>Ставка, % · ${Number(duty.cost)} ОП за изменение</span><input name="rate" type="number" min="0" max="30" step="0.5" value="${Number(duty.rate)}" ${duty.changed_this_turn?'disabled':''}></label><p class="hint">Доход Казны = обеспеченное внутреннее потребление × динамическая цена × ставка. Влияние на лояльность горожан: ${Number(duty.loyalty_change_pp||0).toLocaleString('ru-RU')} п.п. за ход.</p><button type="submit" ${duty.changed_this_turn?'disabled':''}>Сохранить ставку</button></form></div>
      <h4>Ресурсы и внутренняя торговля</h4><p class="hint">Показывается прогноз следующего хода. Динамическая цена меняется постепенно, не более чем на 10% за ход; стрелка показывает направление следующего изменения.</p>${table(['Ресурс','Производство','Потребление','Баланс','Базовая цена','Динамическая цена','Тенденция','Импорт: договор / зоны','Экспорт: договор / зоны','Прибыль'],resourceRows,'Ресурсов пока нет.')}
      <h4>Торговые договоры</h4>${table(['Стороны','Статус','Условия отправителя','Условия получателя','Маршрут'],agreementRows,'Торговых договоров пока нет.')}
      <h4>Пошлины транзитёра по маршрутам</h4>${table(['Договор и маршрут','Стороны','Статус','Ставка, %'],(transit.routes||[]).map(route=>`<tr><td>${tradeRouteNames(route.route_province_ids||[])}</td><td>${escape(route.from_state)} → ${escape(route.to_state)}</td><td>${escape(route.status==='accepted'?'Действует':'Ожидает ответа')}</td><td><form class="route-toll-form" data-agreement-id="${Number(route.agreement_id)}"><input name="rate" type="number" min="0" max="100" step="0.01" value="${Number(route.rate)}" aria-label="Ставка пошлины по маршруту"><button type="submit">Сохранить</button></form></td></tr>`),'Нет чужих договоров, проходящих через ваши провинции.')}${table(['Ход','Стороны','Ресурс / G','Отправлено','Полученная пошлина'],transitRows,'Через ваши территории ещё не проходили договорные поставки.')}</section>
      ${zonePanels}<section data-trade-view="flows" hidden><h4>Межрыночные потоки</h4><p class="hint">Партии оцениваются по цене зоны назначения; доход делят участники зоны происхождения по влиянию.</p>${table(['Маршрут','Ресурс','Государства','Количество','Цена назначения','Оборот','Расстояние'],flows,'Межзонных поставок пока нет.')}</section></div>`;
    host.querySelectorAll('[data-trade-panel]').forEach(button=>button.addEventListener('click',()=>{
      host.querySelectorAll('[data-trade-panel]').forEach(tab=>tab.setAttribute('aria-selected',String(tab===button)));
      host.querySelectorAll('[data-trade-view]').forEach(panel=>{panel.hidden=panel.dataset.tradeView!==button.dataset.tradePanel;});
    }));
    for(const [selector,route] of [['.trade-duty-form','trade-duty']]){
      const form=host.querySelector(selector);
      form?.addEventListener('submit',async event=>{event.preventDefault();const button=form.querySelector('[type="submit"]');button.disabled=true;
        try{await api(`${prefix}/states/${stateId}/${route}`,{method:'POST',body:JSON.stringify({rate:Number(form.elements.rate.value)})});showStatus('Ставка обновлена.',4000);void renderTradeDashboard(host,stateId,productionRows,stateName);}
        catch(error){button.disabled=false;showStatus(error.message,5000);}
      });
    }
    host.querySelectorAll('.route-toll-form').forEach(form=>form.addEventListener('submit',async event=>{
      event.preventDefault();const button=form.querySelector('[type="submit"]');button.disabled=true;
      try{await api(`${prefix}/states/${stateId}/transit-tolls`,{method:'POST',body:JSON.stringify({agreement_id:Number(form.dataset.agreementId),rate:Number(form.elements.rate.value)})});showStatus('Пошлина по маршруту обновлена.',4000);void renderTradeDashboard(host,stateId,productionRows,stateName);}
      catch(error){button.disabled=false;showStatus(error.message,5000);}
    }));
  }catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}
async function renderTradeAgreements(host,stateId){
  host.innerHTML='<p class="hint">Загружаю данные торговли…</p>';
  try{
    const statePrefix=user?.role==='admin'?'admin':'my';
    const [data,settlements,market,interzone,duty,transit]=await Promise.all([api('my/trade-agreements'),api('my/trade-settlements'),api('my/trade-market'),api('my/trade-interzone'),api(`${statePrefix}/states/${Number(stateId)}/trade-duty`),api(`${statePrefix}/states/${Number(stateId)}/transit-toll`)]);if(!host.isConnected)return;
    const relates=item=>Number(item.from_state_id)===Number(stateId)||Number(item.to_state_id)===Number(stateId);
    const tradePrinciples=(data.states||[]).find(state=>Number(state.id)===Number(stateId))?.principles||{};
    const landRouteRange=10+3*['Консорциум','Содружество'].filter(value=>tradePrinciples.structure===value).length+(tradePrinciples.economy==='Гильдии'?3:0);
    const seaRouteRange=10+(tradePrinciples.economy==='Адмиралтейство'?5:0);
    const agreements=(data.agreements||[]).filter(relates),settlementRows=(settlements.lines||[]).filter(line=>Number(line.sender_state_id)===Number(stateId)||Number(line.recipient_state_id)===Number(stateId)||(line.transit_fees||[]).some(fee=>Number(fee.state_id)===Number(stateId))).map(line=>{const fees=(line.transit_fees||[]).map(fee=>`${escape(fee.state_name)} · ${Number(fee.amount||0).toLocaleString('ru-RU')} G`).join('<br>')||'—';return `<tr><td>${Number(line.year)} · ${Number(line.turn)}</td><td>${escape(line.sender)} → ${escape(line.recipient)}</td><td>${line.item_kind==='gold'?'G':escape(line.item_name)}</td><td>${Number(line.sent).toLocaleString('ru-RU')}</td><td>${Number(line.received).toLocaleString('ru-RU')}</td><td>${Number(line.lost).toLocaleString('ru-RU')}</td><td>${fees}</td></tr>`;}).join('');
    const marketRows=(market.lines||[]).filter(line=>Number(line.buyer_state_id)===Number(stateId)||Number(line.seller_state_id)===Number(stateId)).map(line=>`<tr><td>${Number(line.year)} · ${Number(line.turn)}</td><td>${escape(line.zone)}</td><td>${escape(line.resource_name)}</td><td>${escape(line.seller)} → ${escape(line.buyer)}</td><td>${Number(line.quantity).toLocaleString('ru-RU')}</td><td>${Number(line.internal_duty_amount||0).toLocaleString('ru-RU')} G</td><td>${Number(line.buyer_influence||0).toLocaleString('ru-RU')}</td></tr>`).join('');
    const interzoneRows=(interzone.lines||[]).filter(line=>Number(line.buyer_state_id)===Number(stateId)||Number(line.seller_state_id)===Number(stateId)).map(line=>`<tr><td>${Number(line.year)} · ${Number(line.turn)}</td><td>${escape(line.from_zone)} → ${escape(line.to_zone)}</td><td>${escape(line.resource_name)}</td><td>${escape(line.seller)} → ${escape(line.buyer)}</td><td>${Number(line.distance)} пров.</td><td>${Number(line.quantity).toLocaleString('ru-RU')}</td><td>${Number(line.buyer_influence||0).toLocaleString('ru-RU')}</td></tr>`).join('');
    const cards=agreements.map(item=>`<article class="application-panel marriage-candidate"><strong>${escape(item.from_state)} → ${escape(item.to_state)}</strong><span>${escape(item.status==='pending'?'Ожидает ответа':item.status==='accepted'?'Исполняется каждый ход':item.status)}</span><p>Маршрут: ${tradeRouteNames(item.route_province_ids||[])}</p><p>Отправитель: ${tradeTermsText(item.terms?.from_goods,item.terms?.from_gold)}</p><p>Получатель: ${tradeTermsText(item.terms?.to_goods,item.terms?.to_gold)}</p></article>`).join('');
    const loyaltyEffect=Number(duty.loyalty_change_pp||0),dutyForm=`<form class="application-panel trade-duty-form"><h4>Внутренняя пошлина</h4><label class="field"><span>Ставка государства · ${Number(duty.cost)} ОП за изменение</span><input name="rate" type="number" min="0" max="30" step="0.5" value="${Number(duty.rate)}" ${duty.changed_this_turn?'disabled':''}></label><p class="hint">Базовая ставка — 15%. Доход от сбора поступает в Казну государства-покупателя. За каждый ход ставка выше базы снижает лояльность горожан на 0,25 п.п. за каждый процентный пункт ставки; ниже базы — повышает. Сейчас изменение: ${loyaltyEffect>0?'+':''}${loyaltyEffect.toLocaleString('ru-RU')} п.п./ход. ${duty.changed_this_turn?'В этом ходу ставку уже меняли.':''}</p><button type="submit" ${duty.changed_this_turn?'disabled':''}>Изменить ставку</button></form>`;
    host.innerHTML=`<div class="trade-top-cards"><div class="trade-distance-card"><small>Торговая дистанция</small><strong>${landRouteRange} суша · ${seaRouteRange} море</strong><span>Максимальная длина маршрута с учётом Принципов государства.</span></div>${dutyForm}<form class="application-panel transit-toll-form"><h4>Транзитный сбор</h4><label class="field"><span>Ставка за проход договора через государство, %</span><input name="rate" type="number" min="0" max="100" step="0.01" value="${Number(transit.rate)}"></label><p class="hint">По умолчанию 5%; можно установить 0%.</p><button type="submit">Сохранить ставку</button></form></div><p class="hint">Торговые договоры, поставки по ним и распределение товаров в торговых зонах для этого государства.</p><section class="application-panel"><h4>Договоры</h4>${cards||'<p class="hint">Торговых договоров пока нет.</p>'}</section><section class="application-panel"><h4>Поставки по договорам</h4>${settlementRows?`<div class="table-scroll"><table><thead><tr><th>Ход</th><th>Стороны</th><th>Ресурс / G</th><th>Отправлено</th><th>Получено</th><th>Потери</th><th>Пошлины третьих стран</th></tr></thead><tbody>${settlementRows}</tbody></table></div>`:'<p class="hint">Поставок пока нет.</p>'}</section><section class="application-panel"><h4>Рынок торговой зоны</h4>${marketRows?`<div class="table-scroll"><table><thead><tr><th>Ход</th><th>Зона</th><th>Ресурс</th><th>Источник → получатель</th><th>Количество</th><th>Пошлина покупателя</th><th>Влияние получателя</th></tr></thead><tbody>${marketRows}</tbody></table></div>`:'<p class="hint">Расчёт рынка выполняется при смене хода. Пока нет записей завершённых торговых расчётов.</p>'}</section><section class="application-panel"><h4>Поставки между торговыми зонами</h4>${interzoneRows?`<div class="table-scroll"><table><thead><tr><th>Ход</th><th>Маршрут зон</th><th>Ресурс</th><th>Источник → получатель</th><th>Путь</th><th>Количество</th><th>Влияние получателя</th></tr></thead><tbody>${interzoneRows}</tbody></table></div>`:'<p class="hint">Межзонных поставок пока нет.</p>'}</section>`;
    const transitForm=host.querySelector('.transit-toll-form');transitForm?.addEventListener('submit',async event=>{event.preventDefault();const button=transitForm.querySelector('[type="submit"]');button.disabled=true;try{await api(`${statePrefix}/states/${Number(stateId)}/transit-toll`,{method:'POST',body:JSON.stringify({rate:Number(transitForm.elements.rate.value)})});showStatus('Транзитный сбор обновлён.',4000);void renderTradeAgreements(host,stateId);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
    const dutyFormNode=host.querySelector('.trade-duty-form');dutyFormNode?.addEventListener('submit',async event=>{event.preventDefault();const button=dutyFormNode.querySelector('[type="submit"]');button.disabled=true;try{const rate=Number(dutyFormNode.elements.rate.value);const result=await api(`${statePrefix}/states/${Number(stateId)}/trade-duty`,{method:'POST',body:JSON.stringify({rate})});showStatus(result.unchanged?'Ставка не изменилась':`Ставка обновлена${result.cost?` · списано ${result.cost} ОП`:''}`,4000);void renderTradeAgreements(host,stateId);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
  }catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

function renderPlayerStateSection(host,tab,quiet=false){
  if(!user){host.innerHTML='<h3>Государство</h3><p class="hint">Войдите, чтобы открыть государственные данные.</p>';return;}
  if(!quiet)host.innerHTML='<p class="hint">Загружаю государство…</p>';
  api('my/states').then(async states=>{
    if(!host.isConnected||activeMenuSection!==tab)return;
    if(!states.length){host.innerHTML='<h3>Государство</h3><p class="hint">За вашим аккаунтом пока не закреплено государство. Администратор должен назначить его игроку.</p>';return;}
    const chosen=states.find(state=>user.state_ids?.includes(Number(state.id)))||states[0];
    const indicators=await api(`my/states/${Number(chosen.id)}/indicators`);
    if(!host.isConnected||activeMenuSection!==tab)return;
    const stateCategory=categories.find(category=>category.layer==='states'&&category.id===Number(chosen.id));
    const crime=Number(indicators.crime??chosen.crime??stateCategory?.crime??.2);
    const category=(layer,name)=>name?{name,id:categories.find(c=>c.layer===layer&&c.name===name)?.id}:null;
    const provinces=(chosen.provinces||[]).map(p=>({...allProvinces.find(item=>item.id===p.id),...p,layers:{states:{...indicators,id:Number(chosen.id),name:chosen.name,crime},races:category('races',p.race),religions:category('religions',p.religion),resources:category('resources',p.resource)}}));
    provinces.push(...allProvinces.filter(p=>p.kind==='land'&&p.occupation===chosen.name&&!provinces.some(owned=>owned.id===p.id)));
    try{
      const rates=await api(`my/states/${Number(chosen.id)}/estate-tax-rates`);
      const estateRates=Object.fromEntries(rates.groups.map(row=>[row.estate,Number(row.rate)]));
      provinces.forEach(province=>{if(Number(province.layers?.states?.id)===Number(chosen.id))province.layers.states.estate_tax_rates=estateRates;});
    }catch{/* Other player sections remain available if tax data is temporarily unavailable. */}
    if(activeMenuSection===tab)renderStateDetails(host,{...chosen,crime,corruption:indicators.corruption},tab,provinces,false);
  }).catch(error=>{if(host.isConnected&&activeMenuSection===tab)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;});
}

async function renderProductionTradeBalance(host,stateId,productionRows){
  const table=host.querySelector('.state-detail table.state-data-table');
  if(!table)return;
  try{
    const [contracts,market,interzone]=await Promise.all([api('my/trade-settlements'),api('my/trade-market'),api('my/trade-interzone')]);
    if(!table.isConnected)return;
    const sources=[contracts.lines||[],market.lines||[],interzone.lines||[]];
    const all=sources.flat();
    const latest=all.reduce((value,row)=>Math.max(value,Number(row.year)*1000+Number(row.turn)),-Infinity);
    const flows=new Map();
    for(const [index,lines] of sources.entries())for(const line of lines){
      if(Number(line.year)*1000+Number(line.turn)!==latest)continue;
      if(index===0&&line.item_kind!=='resource')continue;
      const resource=index===0?line.item_name:line.resource_name;
      const amount=Number(index===0?line.received:line.quantity)||0;
      const sent=Number(index===0?line.sent:line.quantity)||0;
      if(!flows.has(resource))flows.set(resource,{imports:0,exports:0});
      const flow=flows.get(resource);
      if(Number(line.recipient_state_id??line.buyer_state_id)===stateId)flow.imports+=amount;
      if(Number(line.sender_state_id??line.seller_state_id)===stateId)flow.exports+=sent;
    }
    const rows=[...table.tBodies[0].rows].filter(row=>!row.classList.contains('resource-category-row'));
    rows.forEach((row,index)=>{
      const production=productionRows[index];if(!production)return;
      const flow=flows.get(production.resource)||{imports:0,exports:0};
      const balance=production.balance===null?null:production.balance+flow.imports-flow.exports;
      row.cells[3].textContent=balance===null?'—':balance.toLocaleString('ru-RU');
      row.cells[3].className=balance===null?'':balance>0?'balance-positive':balance<0?'balance-negative':'';
      row.cells[4].textContent=flow.imports.toLocaleString('ru-RU');
      row.cells[5].textContent=flow.exports.toLocaleString('ru-RU');
    });
  }catch(error){
    const hint=table.closest('.state-detail')?.querySelector('.hint');
    if(hint)hint.textContent+=` Торговые потоки недоступны: ${error.message}`;
  }
}

async function renderStateModifierTab(host,state,provinces,isAdmin){
  const target=host.querySelector('[data-state-modifiers]');
  if(!target)return;
  try{
    const prefix=isAdmin?'admin':'my',stateId=Number(state.id);
    const [politics,indicators]=await Promise.all([
      api(`${prefix}/states/${stateId}/politics`),
      api(`${prefix}/states/${stateId}/indicators`),
    ]);
    if(!target.isConnected)return;
    const derived=calculateStatePolitics(provinces,politics,state.name,{...state,corruption:indicators.corruption});
    const number=value=>Number(value||0).toLocaleString('ru-RU',{maximumFractionDigits:2});
    const signedPP=value=>`${value>0?'+':value<0?'−':''}${number(Math.abs(value)*100)} п.п.`;
    const mult=value=>`×${number(value)}`;
    const statusNames={Ключевое:'Ключевое',Значимое:'Значимое',Бесправное:'Бесправное'};
    const estateNames=['Знать','Духовенство','Горожане','Крестьяне'];
    const estateRows=estateNames.map(name=>{
      const row=politics.find(item=>item.group_type==='estate'&&item.group_key===name);
      const b=derived.estateModifierBreakdown[name];
      return `<tr><td>${escape(name)}</td><td>${escape(statusNames[b.status]||b.status)}</td><td>×${number(b.statusWeightFactor)}</td><td>${number(b.baseLoyalty*100)}%</td><td>${signedPP(b.influence)}</td><td>${signedPP(-b.ambition)}</td><td>${signedPP(-b.taxAdjustment)}</td><td>${signedPP(b.corruptionBonus)}</td><td><strong>${number(b.effectiveLoyalty*100)}%</strong></td><td>${derived.estateStability[name]==null?'—':signedPP(derived.estateStability[name])}</td></tr>`;
    }).join('');
    const groupRows=[];
    for(const [kind,layer,breakdowns] of [['Раса','races',derived.raceModifierBreakdown],['Религия','religions',derived.religionModifierBreakdown]]){
      for(const [id,b] of Object.entries(breakdowns)){
        const name=categories.find(item=>item.layer===layer&&String(item.id)===String(id))?.name||String(id);
        const statusEffects=GROUP_STATUS_EFFECTS[b.status]||GROUP_STATUS_EFFECTS.Невмешательство;
        const loyaltyModifier=GROUP_STATUS_LOYALTY_MODIFIERS[b.status]||0;
        const stability=kind==='Раса'?derived.raceStability[id]:derived.religionStability[id];
        groupRows.push(`<tr><td>${kind}</td><td>${escape(name)}</td><td>${escape(b.status)}</td><td>${Number(b.population||0).toLocaleString('ru-RU')}</td><td>${number(b.baseLoyalty*100)}%</td><td>${signedPP(loyaltyModifier)}</td><td><strong>${number(b.effectiveLoyalty*100)}%</strong></td><td>${mult(statusEffects.population)}</td><td>${mult(statusEffects.tax)}</td><td>${mult(statusEffects.production)}</td><td>${mult(statusEffects.recruit)}</td><td>${signedPP(stability||0)}</td></tr>`);
      }
    }
    const crime=Number(indicators.crime??state.crime??0),corruption=Number(indicators.corruption??state.corruption??0),effects=getEconomyConfig().stateEffects||{};
    const permanentModifiers=Array.isArray(indicators.permanent_modifiers)?indicators.permanent_modifiers:[];
    const permanentRows=permanentModifiers.map(item=>{
      const amount=['%','п.п.'].includes(item.unit)?Number(item.value)*100:Number(item.value);
      const formatted=number(amount);
      const valueText=item.unit==='статус'?'Ограничение':['%','п.п.'].includes(item.unit)?`${amount>0?'+':amount<0?'−':''}${formatted} ${item.unit}`:`${amount>0?'+':amount<0?'−':''}${formatted} ${item.unit}`;
      return `<tr><td>${escape(item.effect)}</td><td>${escape(valueText)}</td><td>${escape(item.scope)}</td><td>${escape(item.source)}</td><td>${escape(item.condition||'—')}</td><td>${escape(item.duration)}</td><td>${escape(item.status)}</td></tr>`;
    }).join('');
    const crimeTax=Number(effects.crimeTaxPenalty??.25),crimePopulation=Number(effects.crimePopulationPenalty??.5),crimeRecruit=Number(effects.crimeRecruitBonus??.5),corruptionTax=Number(effects.corruptionTaxPenalty??1);
    const urbanGrowth=Number(indicators.urbanization_growth_multiplier??1);
    const systemRows=[
      `<tr><td>Преступность · ${number(crime*100)}%</td><td>Производство ресурсов</td><td>Государство</td><td>${mult(1-crime)}</td><td>Постоянное значение; штраф участвует в каждом расчёте провинции</td></tr>`,
      `<tr><td>Преступность · ${number(crime*100)}%</td><td>Налоговые поступления</td><td>Государство</td><td>${mult(1-crime*crimeTax)}</td><td>Ставка влияния: ${number(crimeTax*100)}% от уровня преступности</td></tr>`,
      `<tr><td>Преступность · ${number(crime*100)}%</td><td>Прирост населения</td><td>Государство</td><td>${mult(1-crime*crimePopulation)}</td><td>Ставка влияния: ${number(crimePopulation*100)}% от уровня преступности</td></tr>`,
      `<tr><td>Преступность · ${number(crime*100)}%</td><td>Прирост рекрутов</td><td>Государство</td><td>${mult(1+crime*crimeRecruit)}</td><td>Бонус от преступности по действующей формуле</td></tr>`,
      `<tr><td>Коррупция · ${number(corruption*100)}%</td><td>Налоговые поступления</td><td>Государство</td><td>${mult(1-corruption*corruptionTax)}</td><td>Ставка влияния: ${number(corruptionTax*100)}% от уровня коррупции</td></tr>`,
      `<tr><td>Коррупция · ${number(corruption*100)}%</td><td>Лояльность Знати и Духовенства</td><td>Два сословия</td><td>${signedPP(Math.min(Number(effects.corruptionLoyaltyCap??.15),corruption/Number(effects.corruptionLoyaltyDivisor??6)))}</td><td>Добавляется к эффективной лояльности, не к сохранённой</td></tr>`,
      `<tr><td>Урбанизация</td><td>Прирост населения</td><td>Государство</td><td>${mult(urbanGrowth)}</td><td>Множитель от текущего уровня урбанизации</td></tr>`,
    ].join('');
    const peasant=derived.estateModifierBreakdown['Крестьяне'];
    const peasantRaw=peasant?peasant.baseLoyalty+peasant.influence-peasant.ambition-peasant.taxAdjustment+peasant.corruptionBonus:0;
    const peasantExplanation=peasant?`Сохранённая лояльность Крестьян ${number(peasant.baseLoyalty*100)}% + влияние ${number(peasant.influence*100)} п.п. (уже уменьшено коэффициентом статуса ×${number(peasant.statusWeightFactor)}) − ${number(peasant.ambition*100)} п.п. амбиций − ${number(peasant.taxAdjustment*100)} п.п. налоговой поправки + ${number(peasant.corruptionBonus*100)} п.п. от коррупции = ${number(peasantRaw*100)}%; после ограничения 0–100% сейчас ${number(peasant.effectiveLoyalty*100)}%.`:'';
    target.innerHTML=`<p class="hint">Показаны эффекты, которые уже участвуют в формулах государства. Статус прямо меняет вес сословия: Ключевое ×3, Значимое ×1,5, Бесправное ×0,25; экономический вес провинций дополняет этот коэффициент.</p><section class="application-panel"><h4>Постоянные модификаторы</h4><div class="table-scroll"><table class="state-data-table modifier-table"><thead><tr><th>Показатель</th><th>Значение</th><th>Область</th><th>Источник</th><th>Условие</th><th>Срок</th><th>Статус</th></tr></thead><tbody>${permanentRows||'<tr><td colspan="7" class="hint">Нет активных постоянных модификаторов.</td></tr>'}</tbody></table></div></section><section class="application-panel"><h4>Лояльность сословий</h4><div class="table-scroll"><table class="state-data-table modifier-table"><thead><tr><th>Сословие</th><th>Статус</th><th>Коэффициент влияния</th><th>Сохранённая</th><th>Влияние</th><th>Амбиции статуса</th><th>Налоговая поправка</th><th>Коррупция</th><th>Итоговая</th><th>Вклад в стабильность</th></tr></thead><tbody>${estateRows}</tbody></table></div><p class="hint">${peasantExplanation}</p><p class="hint">Лояльность = сохранённая − амбиции статуса − налоговая поправка + бонус коррупции; итог ограничивается диапазоном 0–100%. Статус уменьшает политический вес сословия и тем самым снижает его прибавку к эффективной лояльности.</p></section><section class="application-panel"><h4>Эффекты статусов рас и религий</h4><div class="table-scroll"><table class="state-data-table modifier-table"><thead><tr><th>Тип</th><th>Группа</th><th>Статус</th><th>Население</th><th>Сохранённая лояльность</th><th>Поправка к лояльности</th><th>Итоговая лояльность</th><th>Прирост населения</th><th>Налоги</th><th>Производство</th><th>Рекруты</th><th>Стабилизация</th></tr></thead><tbody>${groupRows.join('')||'<tr><td colspan="12" class="hint">Нет присутствующих рас и религий.</td></tr>'}</tbody></table></div></section><section class="application-panel"><h4>Общегосударственные расчётные эффекты</h4><div class="table-scroll"><table class="state-data-table modifier-table"><thead><tr><th>Источник</th><th>Показатель</th><th>Область</th><th>Текущий эффект</th><th>Правило</th></tr></thead><tbody>${systemRows}</tbody></table></div></section><section class="application-panel"><h4>Временные и назначаемые модификаторы</h4><p class="hint">Предложения и временные эффекты пока не входят в реестр.</p></section>`;
  }catch(error){if(target.isConnected)target.innerHTML=`<p class="form-message">Не удалось загрузить модификаторы: ${escape(error.message)}</p>`;}
}

function renderStateDetails(host,state,tab,provinces,isAdmin){
  if(tab==='Провинции')provinces=[...provinces].sort((a,b)=>(a.province_type==='Столичная'?0:1)-(b.province_type==='Столичная'?0:1)||Number(a.id)-Number(b.id));
  if(isAdmin){
    const pageTitle=$('page-heading')?.querySelector('h1');
    if(pageTitle)pageTitle.textContent=state.name;
    document.title=`${state.name} — Sixième Terre`;
  }
  const ownedProvinces=provinces.filter(p=>Number(p.layers?.states?.id)===Number(state.id));
  const population=ownedProvinces.reduce((sum,p)=>sum+Number(p.population||0),0);
  const provinceEconomy=provinces.map(p=>calculateProvinceEconomy(p,state.name,state));
  const unresolvedTaxes=provinceEconomy.filter(item=>item.taxes===null).length;
  const productionRows=calculateStateProduction(provinces,state.name,state);
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
  const principles=state.principles||{};
  const estateStatuses={
    authority:{
      'Династия':['Ключевое','Значимое','Бесправное','Бесправное'],
      'Магистрат':['Значимое','Ключевое','Ключевое','Бесправное'],
      'Клир':['Бесправное','Ключевое','Бесправное','Бесправное'],
      'Диктат':['Бесправное','Значимое','Бесправное','Бесправное'],
      'Вече':['Бесправное','Значимое','Значимое','Ключевое'],
    },
    economy:{
      'Крепостничество':['Ключевое','—','—','Бесправное'],
      'Гильдии':['—','—','Ключевое','—'],
      'Адмиралтейство':['—','—','Ключевое','—'],
      'Корсарство':['—','—','Значимое','—'],
      'Работорговля':['—','—','—','Бесправное'],
    },
  };
  const estateOrder=['Знать','Духовенство','Горожане','Крестьяне'];
  const estateStatus=name=>{
    const index=estateOrder.indexOf(name);
    const economic=estateStatuses.economy[principles.economy]?.[index];
    return economic&&economic!=='—'?economic:(estateStatuses.authority[principles.authority]?.[index]||'—');
  };
  const allEstateStats=['Знать','Духовенство','Горожане','Крестьяне'].map(name=>{
    const population=ownedProvinces.reduce((sum,province)=>sum+(estatePopulation(province.province_type,Number(province.population)||0)?.[name]||0),0);
    const values=provinces.filter(province=>province.layers?.states?.name===state.name||province.occupation===state.name).map(province=>{
      const count=estatePopulation(province.province_type,Number(province.population)||0)?.[name]||0;
      const value=calculateProvinceValue(province,state.name);
      return value===null?null:value*count/Math.max(1,Number(province.population)||0)*(ESTATE_INFLUENCE_FACTORS[estateStatus(name)]??1);
    });
    return {name,population,weight:values.some(value=>value===null)?null:values.reduce((sum,value)=>sum+value,0)};
  });
  const estateStats=allEstateStats.filter(item=>item.population>0||item.weight>0);
  const totalEstateWeight=allEstateStats.every(item=>item.weight!==null)?allEstateStats.reduce((sum,item)=>sum+item.weight,0):null;
  const pct=value=>`${(value*100).toLocaleString('ru-RU',{minimumFractionDigits:1,maximumFractionDigits:1})}%`;
  const stabilityHint='Вклад группы в стабильность государства; знак показывает повышение или снижение';
  const groupTable=(title,rows,groupType)=>`<h4>${title}</h4><div class="table-scroll"><table class="state-data-table group-status-table"><thead><tr><th>Название</th><th>Статус</th><th>Население</th><th>Доля</th><th>Лояльность</th><th title="${stabilityHint}">Стабилизация</th></tr></thead><tbody>${rows.length?rows.map(row=>{const layer=groupType==='race'?'races':'religions',key=categories.find(c=>c.layer===layer&&c.name===row.name)?.id;return `<tr><td>${escape(row.name)}</td><td><select class="group-status-inline" data-group-status="${groupType}:${key}" data-group-type="${groupType}" data-group-id="${Number(key)}" aria-label="Статус группы ${escape(row.name)}"><option disabled>Официальная</option><option>Признание</option><option>Невмешательство</option><option>Ассимиляция</option><option>Истребление</option></select></td><td>${row.population.toLocaleString('ru-RU')}</td><td>${pct(row.share)}</td><td data-politics-loyalty="${groupType}:${key}">50%</td><td data-politics-stability="${groupType}:${key}" title="${stabilityHint}">—</td></tr>`}).join(''):`<tr><td colspan="6" class="hint">Нет назначенных значений.</td></tr>`}</tbody></table></div>`;
  const principleLabels={authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина'};
  let detail='';
  if(tab==='Статистика'){
    const estatesTable=estateStats.length
      ?`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Статус</th><th>Население</th><th>Влияние</th><th>Лояльность</th><th title="${stabilityHint}">Стабилизация</th><th>Ставка, G/житель</th></tr></thead><tbody>${estateStats.map(item=>`<tr><td>${escape(item.name)}</td><td data-politics-status="estate:${escape(item.name)}">${estateStatus(item.name)}</td><td>${item.population.toLocaleString('ru-RU')}</td><td data-estate-influence="${escape(item.name)}">${totalEstateWeight&&item.weight!==null?pct(item.weight/totalEstateWeight):'—'}</td><td data-politics-loyalty="estate:${escape(item.name)}">50%</td><td data-politics-stability="estate:${escape(item.name)}" title="${stabilityHint}">—</td><td><input class="tax-rate-inline" type="number" min="0" max="10000" step="1" disabled data-tax-estate="${escape(item.name)}" aria-label="Ставка налога сословия ${escape(item.name)}"></td></tr>`).join('')}</tbody></table></div>`
      :'<div class="table-scroll"><table class="state-data-table"><tbody><tr><td class="hint">У государства пока нет населения.</td></tr></tbody></table></div>';
    detail=`<div class="state-identity"><div class="state-emblem-frame"><div class="state-emblem-placeholder" data-emblem-placeholder>Символика<br>не загружена</div><img class="state-emblem-image" data-state-emblem alt="Символика государства" hidden>${isAdmin?`<button type="button" class="state-emblem-edit" data-emblem-toggle aria-label="Редактировать символику" title="Редактировать символику"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 16.5V20h3.5L18 6 4 16.5Z"/><path d="m12.5 8 3.5 3.5M14 4l2-2 6 6-2 2"/></svg></button><div class="state-emblem-menu" data-emblem-menu hidden><button type="button" data-emblem-change>Загрузить / сменить</button><button type="button" class="danger-button" data-emblem-delete hidden>Удалить символику</button></div><input type="file" data-emblem-file accept="image/jpeg,image/png,image/webp" hidden>`:''}</div><div class="state-identity-facts"><div><small>Текущий правитель</small><strong data-current-ruler>Загружаю…</strong><small>Форма правления</small><strong>${escape(state.form_name||'Не задана')}</strong></div><div><small>Официальная раса</small><strong>${escape(state.official_race||'—')}</strong><small>Официальная религия</small><strong>${escape(state.official_religion||'—')}</strong></div></div></div><div class="state-dashboard-top"><section class="state-dashboard-card"><h4>Состояние государства</h4><div class="state-condition-list"><div><small>Лимит развития</small><strong data-indicator="development_limit">…</strong></div><div><small>Совокупное развитие</small><strong data-indicator="total_development">…</strong></div><div><small>Нагрузка на управление</small><strong data-management-overload>…</strong></div><div><small>Стабильность государства</small><strong data-state-stability>—</strong></div><div><small>Базовая эффективность налогообложения</small><strong data-tax-efficiency>—</strong></div><div class="state-condition-percent"><small>Коррупция</small><strong data-indicator-percent="corruption">…</strong><small data-corruption-last-change></small></div><div class="state-condition-percent"><small>Преступность</small><strong data-indicator-percent="crime">…</strong><small data-crime-last-change></small></div></div><p class="hint" data-indicator-warning></p>${isAdmin?`<form data-development-limit-form class="inline-actions"><label>Лимит развития <input name="development_limit" type="number" min="0" max="2147483647" step="1" required style="width:8em"></label><button type="submit">Сохранить</button><span class="form-message" role="status"></span></form>`:''}</section><section class="state-dashboard-card"><h4>Население</h4><div class="table-scroll"><table class="state-data-table state-population-table"><thead><tr><th>Показатель</th><th>Численность</th></tr></thead><tbody><tr><td>Городское</td><td><span data-indicator="urban_population">…</span></td></tr><tr><td>Сельское</td><td><span data-indicator="rural_population">…</span></td></tr><tr><td>Общее</td><td data-indicator="population">…</td></tr><tr><td>Урбанизация</td><td data-indicator-percent="urbanization">…</td></tr><tr><td>Влияние на прирост (порог <span data-urbanization-threshold>15</span>%)</td><td data-urbanization-effect>…</td></tr><tr><td>Влияние преступности на прирост</td><td data-crime-population-effect>…</td></tr><tr><td>Расчётный прирост</td><td data-indicator="population_growth">…</td></tr></tbody></table></div></section></div><div class="state-dashboard-finances" data-state-finances><section class="state-dashboard-card"><h4>Казна</h4><div class="hint">Загружаю…</div></section><section class="state-dashboard-card"><h4>Престиж</h4><div class="hint">Загружаю…</div></section></div><h4>Сословия</h4>${estatesTable}${groupTable('Расы',groupStats('races',state.official_race),'race')}${groupTable('Религии',groupStats('religions',state.official_religion),'religion')}<p class="hint">Вес сословия учитывает его долю населения в каждой провинции; оккупант получает 50% веса. Влияние считается по четырём сословиям. Лояльность учитывает влияние, амбиции статуса и отклонение налоговой нагрузки от базовой. ${unresolvedTaxes?`Не рассчитано провинций по налогам: ${unresolvedTaxes}.`:''}</p><p class="hint">Каждую ставку можно менять раз в ход: 3 ОП за изменённую группу; администратору бесплатно.</p><div class="inline-actions"><button type="button" class="primary" data-tax-save-all disabled>Сохранить</button></div><p class="form-message" data-tax-save-message role="status"></p>`;
  }
  if(tab==='Экономика')detail='<div data-state-economy><p class="hint">Загружаю финансовые показатели…</p></div>';
  else if(tab==='Власть и династия')detail=`<div class="state-power-grid ${isAdmin?'admin':''}"><div class="state-power-overview"><div class="government-card"><small>Форма правления</small><strong>${escape(state.form_name||'Не задана')}</strong></div><div class="state-facts">${Object.entries(principles).sort(([a],[b])=>['authority','structure','economy','military'].indexOf(a)-['authority','structure','economy','military'].indexOf(b)).map(([key,value])=>`<p><span>${escape(principleLabels[key]||key)}</span><strong>${escape(value)}</strong></p>`).join('')||'<p class="hint">Принципы государства не заданы.</p>'}</div></div><div data-succession-panel><p class="hint">Загружаю сведения о передаче власти…</p></div></div><div class="state-power-content" data-family-table></div>`;
  else if(tab==='Провинции')detail=`<p class="hint">Территорий государства: ${Number(state.province_count??ownedProvinces.length).toLocaleString('ru-RU')}; оккупировано у других государств: ${provinces.filter(p=>p.occupation===state.name&&p.layers?.states?.name!==state.name).length}. Рекрутский прирост — пополнение за ход, лимит — вместимость набора. Оккупант получает 50% экономических показателей провинции. Нажмите заголовок, чтобы отсортировать таблицу.</p><div class="table-scroll provinces-table-scroll"><table class="state-data-table provinces-data-table"><thead><tr>${['Название провинции','ID','Раса','Религия','Тип пров.','Торговый статус','Ресурс','Население','Рост населения','Ценность','КМ, %','Налоги','Торг. влияние','Производство','Прирост рекр.','Лимит рекр.','Ассимиляция расы','Ассимиляция религии'].map((label,index)=>`<th><button type="button" class="province-sort-button" data-sort-column="${index}" aria-label="Сортировать по столбцу ${label}">${label}<span aria-hidden="true"> ↕</span></button></th>`).join('')}</tr></thead><tbody>${provinces.length?provinces.map(p=>{const economy=calculateProvinceEconomy(p,state.name,state),value=calculateProvinceValue(p,state.name,state),occupied=p.occupation===state.name&&p.layers?.states?.name!==state.name;return `<tr class="${occupied?'occupied-province-row':''}"><td>${escape(p.name||'—')}${occupied?' · Оккупирована':''}</td><td>${p.id}</td><td>${escape(p.layers?.races?.name||'—')}</td><td>${escape(p.layers?.religions?.name||'—')}</td><td>${escape(p.province_type||'—')}</td><td>${escape(p.trade_status||'Отсутствует')}</td><td>${escape(p.layers?.resources?.name||'—')}</td><td>${Number(p.population||0).toLocaleString('ru-RU')}</td><td>${economy.populationGrowth===null?'—':economy.populationGrowth.toLocaleString('ru-RU')}</td><td>${value===null?'—':value.toLocaleString('ru-RU')}</td><td>${Number(p.control??100).toLocaleString('ru-RU')}%</td><td>${economy.taxes===null?'—':economy.taxes.toLocaleString('ru-RU')}</td><td>${economy.tradeInfluence===null?'—':economy.tradeInfluence.toLocaleString('ru-RU')}</td><td>${economy.production===null?'—':economy.production.toLocaleString('ru-RU')}</td><td>${economy.recruitGrowth===null?'—':economy.recruitGrowth.toLocaleString('ru-RU')}</td><td>${economy.recruitLimit===null?'—':economy.recruitLimit.toLocaleString('ru-RU')}</td><td>${Number(p.race_assimilation_turns)>0?`${Number(p.race_assimilation_turns)} ход.`:'—'}</td><td>${Number(p.religion_assimilation_turns)>0?`${Number(p.religion_assimilation_turns)} ход.`:'—'}</td></tr>`}).join(''):'<tr><td colspan="18" class="hint">У государства пока нет провинций.</td></tr>'}</tbody></table></div>`;
  else if(tab==='Экономика')detail=`<div data-state-economy><p class="hint">Загружаю финансовые показатели…</p></div>`;
  else if(tab==='Дипломатия')detail=`<div data-state-diplomacy><p class="hint">Загружаю дипломатические предложения…</p></div>`;
  else if(tab==='Военное дело')detail=`<div data-state-military><p class="hint">Загружаю военное дело…</p></div>`;
  else if(tab==='Торговля')detail=`<div data-state-trade><p class="hint">Загружаю торговые данные…</p></div>`;
  else if(tab==='Модификаторы')detail=`<div data-state-modifiers><p class="hint">Загружаю действующие модификаторы…</p></div>`;
  else if(tab==='Производство'){
    const resourceGroups=[...new Set(productionRows.map(row=>row.category))];
    const rows=resourceGroups.map(category=>`<tr class="resource-category-row"><th colspan="6">${escape(category)}</th></tr>${productionRows.filter(row=>row.category===category).map(row=>`<tr><td>${escape(row.resource)}</td><td>${row.production===null?'—':row.production.toLocaleString('ru-RU')}</td><td>${row.consumption.toLocaleString('ru-RU')}</td><td class="${row.balance===null?'':row.balance>0?'balance-positive':row.balance<0?'balance-negative':''}">${row.balance===null?'—':row.balance.toLocaleString('ru-RU')}</td><td>—</td><td>—</td></tr>`).join('')}`).join('');
    const unresolved=productionRows.filter(row=>row.unresolved).length;
    detail=`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Ресурс</th><th>Производство</th><th>Потребление</th><th>Баланс</th><th>Импорт</th><th>Экспорт</th></tr></thead><tbody>${rows}</tbody></table></div><p class="hint">Производство рассчитано по назначенному ресурсу, населению, типу провинции и контролю, затем уменьшено на преступность государства (${Math.floor(crime*100)}%). Потребление = округление вниз от населения / 10 × коэффициент. Все объёмы отображаются целыми числами. Эфемерная и Магическая пустоши в таблицу не включаются. ${unresolved?`Не рассчитано ресурсных строк: ${unresolved} из-за отсутствующих входных данных.`:''} Баланс учитывает договорные и зональные поставки последнего расчётного хода; запасы не ведутся.</p>`;
  }
  if(!detail)detail=`<div class="empty-page"><span class="badge">В РАЗРАБОТКЕ</span><h2>${escape(tab)}</h2><p>Содержание раздела пока не опубликовано.</p></div>`;
  host.innerHTML=`<div class="state-menu stack">${isAdmin?'<button id="state-back" type="button">← Все государства</button>':''}${!isAdmin?`<div class="state-heading"><h3>${escape(state.name)}</h3></div>`:''}${isAdmin?`<nav class="state-subtabs" aria-label="Разделы государства">${STATE_SECTIONS.map(name=>`<button type="button" data-state-tab="${escape(name)}" class="${name===tab?'active':''}">${name==='Статистика'?'Обзор':escape(name)}</button>`).join('')}</nav>`:''}<section class="state-detail"><h3>${escape(tab==='Статистика'?'Обзор':tab)}</h3>${detail}</section>${isAdmin?'<button id="state-delete" class="danger-button" type="button">Удалить государство</button>':''}</div>`;
  if(tab==='Модификаторы')void renderStateModifierTab(host,state,provinces,isAdmin);
  if(isAdmin){
    const picker=document.createElement('label');picker.className='page-tab-picker';picker.innerHTML=`<span>Раздел государства</span><select aria-label="Раздел государства">${STATE_SECTIONS.map(name=>`<option value="${escape(name)}" ${name===tab?'selected':''}>${name==='Статистика'?'Обзор':escape(name)}</option>`).join('')}</select>`;
    host.querySelector('.state-subtabs').after(picker);
    picker.querySelector('select').onchange=event=>{if(confirmLeaveEdits())renderStatesContent(host,state.id,event.target.value);else event.target.value=tab;};
  }
  if(tab==='Статистика'){
    const root=host.querySelector('.state-detail'),identity=root.querySelector('.state-identity'),finances=root.querySelector('[data-state-finances]');
    if(identity&&finances)identity.append(finances);
    const urbanCell=root.querySelector('[data-indicator-percent="urbanization"]');
    if(urbanCell){
      urbanCell.closest('tr').remove();
      const metric=document.createElement('div');metric.innerHTML='<small>Урбанизация</small><strong data-indicator-percent="urbanization">…</strong>';
      root.querySelector('.state-condition-list')?.append(metric);
    }
    const estateHeading=[...root.children].find(node=>node.tagName==='H4'&&node.textContent.trim()==='Сословия');
    if(estateHeading){const more=document.createElement('details');more.className='overview-details';const summary=document.createElement('summary');summary.textContent='Сословия и налоговые ставки';more.append(summary);let node=estateHeading;while(node){const next=node.nextSibling;more.append(node);node=next;}root.append(more);}
  }
  if(tab==='Провинции'){
    void renderColonizationMissions(host.querySelector('.state-detail'),Number(state.id));
    const hint=host.querySelector('.state-detail > p.hint');
    hint?.remove();
  }
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
  if(tab==='Военное дело')void renderMilitaryPanel(host.querySelector('[data-state-military]'),{stateId:Number(state.id),notify:message=>showStatus(message,4000),onMapChange:()=>emit('map:refresh')});
  if(tab==='Торговля')renderTradeDashboard(host.querySelector('[data-state-trade]'),Number(state.id),productionRows,state.name);
  if(tab==='Производство')void renderProductionTradeBalance(host,Number(state.id),productionRows);
  if(tab==='Власть и династия'){
    const familyHost=host.querySelector('[data-family-table]');
    const route=`${isAdmin?'admin':'my'}/states/${Number(state.id)}/characters`;
    const marriagesRoute=`${isAdmin?'admin':'my'}/states/${Number(state.id)}/marriages`;
    const successionRoute=`${isAdmin?'admin':'my'}/states/${Number(state.id)}/succession`;
    const familyRequests=[api(route),api(marriagesRoute)];
    if(!isAdmin)familyRequests.push(api(`my/states/${Number(state.id)}/birth-events`),api(`my/states/${Number(state.id)}/marriage-candidates`));
    familyRequests.push(api(successionRoute));
    Promise.all(familyRequests).then(results=>{
      const characters=results[0],activeMarriages=results[1],birthEvents=isAdmin?[]:results[2],marriageInfo=isAdmin?null:results[3],successionInfo=isAdmin?results[2]:results[4];
      if(!familyHost?.isConnected)return;
      const familyTable=characters.length?`<div class="table-scroll"><table class="state-data-table family-character-table"><thead><tr><th>Имя</th><th>Фамилия</th><th>Родство</th><th>Возраст</th><th>Раса</th><th>Религия</th><th>Наследование</th><th>Статус</th></tr></thead><tbody>${characters.map(person=>`<tr class="${person.alive?'':'family-character-dead'}"><td>${escape(person.title?`${person.title} `:'')}${escape(person.name||'—')}${person.is_current_ruler?' <small>(правитель)</small>':''}${person.is_regent?' <small>(регент)</small>':''}</td><td>${escape(person.surname||'—')}</td><td>${escape(person.relationship||'Родственник')}${person.state_name&&person.state_name!==state.name?` · ${escape(person.state_name)}`:''}</td><td>${Number(person.age)} лет</td><td>${escape(person.race||'—')}</td><td>${escape(person.religion||'—')}</td><td>${escape(person.legitimacy||'Неприменимо')}</td><td>${person.alive?'Жив':'Мёртв'}</td></tr>`).join('')}</tbody></table></div>`:'<p class="hint">Профиль правителя ещё не заполнен.</p>';
      const marriagePanel=activeMarriages?.length?`<section class="application-panel"><h4>Браки</h4><div class="marriage-candidates">${activeMarriages.map(marriage=>`<article class="application-panel marriage-candidate"><strong>${marriage.type==='dynastic'?'Династический':'Местный'} брак</strong><span>${escape(marriage.character_a)} — ${escape(marriage.character_b)}</span><span class="hint">${escape(marriage.state_a)} — ${escape(marriage.state_b)}${marriage.type==='dynastic'?' · расторжение стоит 5 ОП':''}</span><button type="button" class="danger-button" data-dissolve-marriage="${Number(marriage.id)}" data-marriage-type="${escape(marriage.type)}">Расторгнуть брак${marriage.type==='dynastic'?' · 5 ОП':''}</button></article>`).join('')}</div></section>`:'';
      const birthForms=birthEvents.map(event=>`<form class="application-panel birth-naming-form" data-birth-event="${event.id}"><strong>Рождение · ${event.children.length} ${event.children.length===1?'ребёнок':'ребёнка'}</strong>${event.children.map((child,index)=>`<label class="field"><span>${child.gender}, ${escape(categories.find(item=>item.layer==='races'&&item.id===Number(child.race_id))?.name||'раса не указана')} · имя ${index+1}</span><input name="child-name" maxlength="120" required></label>`).join('')}<button class="primary" type="submit">Сохранить имена</button></form>`).join('');
      const marriageCandidates=marriageInfo?.candidates?.length?`<section class="application-panel"><h4>Поиск местного супруга</h4><p class="hint">Заключение брака стоит 10 ОП. Поддержка кандидатов сословиями отображается отдельно.</p><div class="marriage-candidates">${marriageInfo.candidates.map(candidate=>`<article class="application-panel marriage-candidate"><strong>${escape(candidate.name)} ${escape(candidate.surname)}</strong><span>${Number(candidate.age)} лет · ${escape(candidate.race)} · ${escape(candidate.religion)}</span><span class="hint">Поддерживают: ${escape(candidate.supported_by?.join(', ')||'пока никто')}</span><button type="button" data-marry-candidate="${candidate.id}">Заключить брак · 10 ОП</button></article>`).join('')}</div></section>`:(!characters.some(person=>person.relationship==='Супруга'||person.relationship==='Супруг')&&marriageInfo?.message?`<p class="hint">${escape(marriageInfo.message)}</p>`:'');
      const successionCandidates=successionInfo?.candidates||[];
      const successionPanel=`${successionInfo?.pending?`<section class="application-panel succession-panel"><h4>${successionInfo.event_type==='election'?'Выборы правителя':'Выбор наследника'}</h4><p>${escape(successionInfo.reason)}. После выбора кандидат вступит в должность при смене хода ${Number(successionInfo.resolves_turn)}. Престиж будет установлен на 10 ОП.</p>${successionInfo.chosen?'<p class="hint">Кандидат выбран; ожидается смена хода.</p>':`<div class="marriage-candidates">${successionCandidates.map((candidate,index)=>`<article class="application-panel marriage-candidate"><strong>${escape(candidate.name)} ${escape(candidate.surname)}</strong><span>${Number(candidate.age)} лет · ${escape(candidate.gender)} · ${escape(candidate.race||'—')} · ${escape(candidate.religion||'—')}</span>${candidate.support?`<span class="hint">Поддерживают: ${escape(Object.entries(candidate.support).filter(([,supported])=>supported).map(([group])=>group).join(', ')||'нет сословий')}</span>`:''}${candidate.support_votes!==undefined?`<span class="hint">Поддержка провинций: ${Number(candidate.support_votes)}</span>`:''}<button type="button" data-succession-choice="${index+1}">Выбрать кандидата</button></article>`).join('')}</div>`}</section>`:''}${!isAdmin?`<section class="application-panel succession-panel"><h4>Передача власти</h4>${principles.authority==='Династия'?`<label class="field"><span>Назначить законного наследника · 15 ОП и −15 п.п. ключевым сословиям</span><select data-designated-heir><option value="">Выберите живого законного ребёнка</option>${characters.filter(person=>person.alive&&person.relationship==='Ребёнок'&&person.legitimacy==='Законный').map(person=>`<option value="${person.id}" ${Number(successionInfo?.designated_heir_id)===Number(person.id)?'selected':''}>${escape(person.name)} ${escape(person.surname)} · ${person.age}</option>`).join('')}</select></label><button type="button" data-designate-heir ${characters.some(person=>person.alive&&person.relationship==='Ребёнок'&&person.legitimacy==='Законный')?'':'disabled'}>Назначить наследника</button>`:''}${principles.authority==='Диктат'?`<label class="field"><span>Назначенный преемник</span><select data-designated-successor><option value="">Выберите персонажа</option>${characters.filter(person=>person.alive&&Number(person.age)>=16).map(person=>`<option value="${person.id}" ${Number(successionInfo?.designated_successor_id)===Number(person.id)?'selected':''}>${escape(person.name)} ${escape(person.surname)} · ${person.age}</option>`).join('')}</select></label><button type="button" data-designate-successor>Назначить преемника</button>`:''}<button type="button" class="danger-button" data-abdicate>Отречься от власти</button></section>`:''}`;
      const successionHost=host.querySelector('[data-succession-panel]');
      if(successionHost)successionHost.innerHTML=successionPanel||(!isAdmin?'<section class="application-panel succession-panel"><h4>Передача власти</h4><button type="button" class="danger-button" data-abdicate>Отречься от власти</button></section>':'');
      familyHost.innerHTML=`${birthForms}${!isAdmin?marriageCandidates:''}${marriagePanel}<section class="family-registry"><h4>Правитель и семья</h4>${familyTable}</section>`;
      const spousePanel=[...familyHost.querySelectorAll(':scope > section.application-panel')].find(panel=>panel.querySelector('h4')?.textContent==='Поиск местного супруга');
      if(spousePanel){const details=document.createElement('details');details.className='application-panel local-spouse-search';const summary=document.createElement('summary');summary.textContent='Поиск местного супруга';details.append(summary);spousePanel.querySelector('h4').remove();while(spousePanel.firstChild)details.append(spousePanel.firstChild);spousePanel.replaceWith(details);}
      familyHost.querySelectorAll('.birth-naming-form').forEach(form=>form.onsubmit=async event=>{event.preventDefault();const names=[...form.querySelectorAll('[name="child-name"]')].map(input=>input.value.trim());const button=form.querySelector('[type="submit"]');button.disabled=true;try{await api(`my/states/${Number(state.id)}/birth-events/${form.dataset.birthEvent}/name`,{method:'POST',body:JSON.stringify({names})});showStatus('Имена детей сохранены',3000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      familyHost.querySelectorAll('[data-marry-candidate]').forEach(button=>button.onclick=async()=>{if(!confirm('Заключить местный брак и потратить 10 ОП?'))return;button.disabled=true;try{await api(`my/states/${Number(state.id)}/marriages/local`,{method:'POST',body:JSON.stringify({candidate_id:Number(button.dataset.marryCandidate)})});showStatus('Брак заключён',3000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      familyHost.querySelectorAll('[data-dissolve-marriage]').forEach(button=>button.onclick=async()=>{const dynastic=button.dataset.marriageType==='dynastic';if(!confirm(`Расторгнуть брак?${dynastic?' С государства будет списано 5 ОП.':''}`))return;button.disabled=true;try{await api(`${marriagesRoute}/${Number(button.dataset.dissolveMarriage)}/dissolve`,{method:'POST',body:'{}'});showStatus(dynastic?'Брак расторгнут; списано 5 ОП':'Брак расторгнут',4000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      successionHost?.querySelectorAll('[data-succession-choice]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{await api(`${successionRoute}/events/${Number(successionInfo.id)}/choose`,{method:'POST',body:JSON.stringify({candidate:Number(button.dataset.successionChoice)})});showStatus('Преемник выбран; вступление состоится при указанной смене хода',5000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      successionHost?.querySelector('[data-abdicate]')?.addEventListener('click',async event=>{const button=event.currentTarget;if(!confirm('Отречение необратимо и немедленно запустит передачу власти. Продолжить?'))return;button.disabled=true;try{await api(`my/states/${Number(state.id)}/abdicate`,{method:'POST',body:JSON.stringify({confirmed:true})});showStatus('Отречение принято; начата передача власти',5000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
      for(const [kind,selector] of [['heir','[data-designate-heir]'],['successor','[data-designate-successor]']])successionHost?.querySelector(selector)?.addEventListener('click',async event=>{const button=event.currentTarget;const select=successionHost.querySelector(kind==='heir'?'[data-designated-heir]':'[data-designated-successor]');if(!select?.value){showStatus('Сначала выберите персонажа',3500);return;}if(kind==='heir'&&!confirm('Назначение стоит 15 ОП и снизит лояльность ключевых сословий на 15 п.п. Подтвердить?'))return;button.disabled=true;try{await api(`my/states/${Number(state.id)}/designate`,{method:'POST',body:JSON.stringify({kind,character_id:Number(select.value)})});showStatus(kind==='heir'?'Наследник назначен':'Преемник назначен',4000);renderStateDetails(host,state,tab,provinces,isAdmin);}catch(error){button.disabled=false;showStatus(error.message,5000);}});
    }).catch(error=>{if(familyHost?.isConnected)familyHost.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;});
  }
  if(tab==='Статистика'){
    bindStateEmblem(host,state,isAdmin);
    const overviewRoot=host.querySelector('.state-detail');
    const indicatorPath=`${isAdmin?'admin':'my'}/states/${Number(state.id)}/indicators`;
    const applyIndicators=data=>{
      if(!overviewRoot?.isConnected||host.querySelector('.state-detail')!==overviewRoot)return;
      host.querySelectorAll('[data-indicator]').forEach(cell=>{
        const value=data[cell.dataset.indicator];
        cell.textContent=value==null?'—':Number(value).toLocaleString('ru-RU',{maximumFractionDigits:cell.dataset.indicator.endsWith('multiplier')?3:0});
      });
      host.querySelectorAll('[data-indicator-percent]').forEach(cell=>{
        const value=data[cell.dataset.indicatorPercent];
        cell.textContent=value==null?'—':`${(Number(value)*100).toLocaleString('ru-RU',{maximumFractionDigits:cell.dataset.indicatorPercent==='corruption'?5:2})}%`;
      });
      host.querySelector('[data-state-stability]').textContent=`${(data.stability*100).toLocaleString('ru-RU',{maximumFractionDigits:2})}%`;
      const taxEfficiency=host.querySelector('[data-tax-efficiency]');if(taxEfficiency)taxEfficiency.textContent=data.base_tax_efficiency==null?'—':`${(Number(data.base_tax_efficiency)*100).toLocaleString('ru-RU',{maximumFractionDigits:1})}%`;
      const urbanPenalty=(1-data.urbanization_growth_multiplier)*100;
      host.querySelector('[data-urbanization-effect]').textContent=`${urbanPenalty>0?'−':''}${urbanPenalty.toLocaleString('ru-RU',{maximumFractionDigits:2})}%`;
      host.querySelector('[data-urbanization-threshold]').textContent=(data.state_effect_coefficients.urbanizationThreshold*100).toLocaleString('ru-RU');
      const crimePenalty=(1-data.crime_population_growth_multiplier)*100;
      host.querySelector('[data-crime-population-effect]').textContent=`${crimePenalty>0?'−':''}${crimePenalty.toLocaleString('ru-RU',{maximumFractionDigits:2})}%`;
      host.querySelector('[data-management-overload]').textContent=data.total_development==null?'—':`${Number(data.overload).toLocaleString('ru-RU')} (${data.overload_ratio==null?'нулевой лимит':`${(data.overload_ratio*100).toLocaleString('ru-RU',{maximumFractionDigits:2})}%`})`;
      host.querySelector('[data-indicator-warning]').textContent=[data.population===0?'У государства нет населения; урбанизация 0%.':'',data.missing_development_count?`Не задано развитие провинций: ${data.missing_development_count}. Сумма неполная.`:''].filter(Boolean).join(' ');
      const last=data.last_turn;
      host.querySelectorAll('.state-condition-list strong').forEach(value=>{
        value.tabIndex=0;value.setAttribute('role','button');value.title='Показать формулу и источники';
        const reveal=()=>{const details=host.querySelector('.state-dashboard-card details')||host.querySelector('.overview-details');if(details)details.open=true;};
        value.onclick=reveal;value.onkeydown=event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();reveal();}};
      });
      const bonus=host.querySelector('[data-corruption-loyalty-bonus]');if(bonus)bonus.textContent=`+${(data.corruption_loyalty_bonus*100).toLocaleString('ru-RU',{maximumFractionDigits:3})} п.п.`;
      if(last?.corruption_change_pp!=null)host.querySelector('[data-corruption-last-change]').textContent=`За последний ход: ${last.corruption_change_pp>0?'+':''}${Number(last.corruption_change_pp).toLocaleString('ru-RU',{maximumFractionDigits:5})} п.п.`;
      if(last?.crime_change_pp!=null)host.querySelector('[data-crime-last-change]').textContent=`За последний ход: ${last.crime_change_pp>0?'+':''}${Number(last.crime_change_pp).toLocaleString('ru-RU')} п.п.`;
      const input=host.querySelector('[name="development_limit"]');if(input)input.value=data.development_limit;
    };
    api(indicatorPath).then(applyIndicators).catch(error=>{if(overviewRoot?.isConnected&&host.querySelector('.state-detail')===overviewRoot){const warning=host.querySelector('[data-indicator-warning]');if(warning)warning.textContent=`Не удалось загрузить показатели: ${error.message}`;}});
    host.querySelector('[data-development-limit-form]')?.addEventListener('submit',async event=>{
      event.preventDefault();const form=event.currentTarget,button=form.querySelector('button'),message=form.querySelector('[role="status"]');
      button.disabled=true;
      try{await api(indicatorPath,{method:'PATCH',body:JSON.stringify({development_limit:Number(form.elements.development_limit.value)})});applyIndicators(await api(indicatorPath));message.textContent='Сохранено';}
      catch(error){message.textContent=error.message;}finally{button.disabled=false;}
    });
    const rulerTarget=host.querySelector('[data-current-ruler]');
    api(`${isAdmin?'admin':'my'}/states/${Number(state.id)}/characters`).then(characters=>{
      if(!rulerTarget?.isConnected)return;
      const ruler=characters.find(person=>person.is_current_ruler&&person.alive);
      rulerTarget.textContent=ruler?`${ruler.title?`${ruler.title} `:''}${ruler.name} ${ruler.surname||''}`.trim():'Нет действующего правителя';
    }).catch(error=>{if(rulerTarget?.isConnected)rulerTarget.textContent='Не удалось загрузить';});
    api(`${isAdmin?'admin':'my'}/states/${Number(state.id)}/politics`).then(rows=>{
      if(!host.isConnected||!Array.isArray(rows))return;
      const politics=new Map(rows.map(row=>[`${row.group_type}:${row.group_key}`,row]));
      const derived=calculateStatePolitics(provinces,rows,state.name,state);
      host.querySelectorAll('[data-group-status]').forEach(input=>{const key=`${input.dataset.groupType}:${input.dataset.groupId}`,row=politics.get(key);if(row){input.value=row.status;input.dataset.originalValue=row.status;input.disabled=row.status==='Официальная'||(user?.role!=='admin'&&row.changed_this_turn);}});
      host.querySelectorAll('[data-politics-loyalty]').forEach(cell=>{const key=cell.dataset.politicsLoyalty,row=politics.get(key),loyalty=key.startsWith('estate:')?derived.estateLoyalty[key.slice(7)]:key.startsWith('race:')?derived.raceLoyalty[key.slice(5)]:key.startsWith('religion:')?derived.religionLoyalty[key.slice(9)]:Number(row?.loyalty);if(Number.isFinite(loyalty))cell.textContent=`${(loyalty*100).toLocaleString('ru-RU',{maximumFractionDigits:1})}%`;});
      host.querySelectorAll('[data-estate-influence]').forEach(cell=>{const value=derived.estateInfluence[cell.dataset.estateInfluence];if(Number.isFinite(value))cell.textContent=pct(value);});
      host.querySelectorAll('[data-politics-stability]').forEach(cell=>{const key=cell.dataset.politicsStability,row=politics.get(key);if(!row){cell.textContent='—';return;}const value=key.startsWith('estate:')?derived.estateStability[key.slice(7)]:key.startsWith('race:')?derived.raceStability[key.slice(5)]:key.startsWith('religion:')?derived.religionStability[key.slice(9)]:null;if(value===null||value===undefined||!Number.isFinite(value)){cell.textContent='—';return;}const sign=value>0?'+':value<0?'−':'';cell.textContent=`${sign}${Math.abs(value*100).toLocaleString('ru-RU',{maximumFractionDigits:2})} п.п.`;});

    }).catch(error=>showStatus(`Не удалось загрузить лояльность: ${error.message}`,4500));
  }
  if(tab==='Провинции'){
    const table=host.querySelector('.provinces-data-table');
    const scroll=host.querySelector('.provinces-table-scroll');
    if(table&&scroll){
      const toolbar=document.createElement('div');toolbar.className='province-table-toolbar';
      toolbar.innerHTML=`<label class="field"><span>Поиск провинции</span><input type="search" data-province-search placeholder="Название или ID" value="${escape(provinceSearchQuery)}"></label><label class="field"><span>Показатели</span><select data-province-columns><option>Основное</option><option>Население</option><option>Экономика</option><option>Торговля</option><option>Управление</option><option>Все</option></select></label><output data-province-count></output>`;
      scroll.before(toolbar);
      const presets={'Основное':[0,1,2,3,4,6,8,10],'Население':[0,1,2,3,8,9,15,16],'Экономика':[0,1,6,7,8,10,11,12,14],'Торговля':[0,1,5,7,12,13,14],'Управление':[0,1,4,6,10,11,15,16]};
      const preset=toolbar.querySelector('[data-province-columns]'),search=toolbar.querySelector('[data-province-search]');
      preset.value=provinceColumnPreset;
      const updateColumns=()=>{
        provinceColumnPreset=preset.value;
        const visible=presets[provinceColumnPreset];
        [...table.rows].forEach(row=>[...row.cells].forEach((cell,index)=>{if(row.cells.length>1)cell.hidden=Boolean(visible&&!visible.includes(index));}));
        table.classList.toggle('compact-columns',Boolean(visible));
      };
      const updateFilter=()=>{
        provinceSearchQuery=search.value.trim();const needle=provinceSearchQuery.toLocaleLowerCase('ru');let shown=0;
        [...table.tBodies[0].rows].forEach(row=>{const name=row.querySelector('[data-province-name]')?.value||row.cells[0]?.textContent||'';const id=row.cells[1]?.textContent||'';row.hidden=Boolean(needle&&!`${name} ${id}`.toLocaleLowerCase('ru').includes(needle));if(!row.hidden)shown++;});
        toolbar.querySelector('[data-province-count]').textContent=`Показано: ${shown} из ${table.tBodies[0].rows.length}`;
      };
      preset.onchange=updateColumns;search.oninput=updateFilter;
      updateColumns();updateFilter();
      table.querySelectorAll('tbody tr').forEach(row=>{const cell=row.cells[1];if(!cell)return;const id=Number(cell.textContent);if(!Number.isFinite(id))return;cell.innerHTML=`<button type="button" class="province-map-link" data-show-province="${id}" aria-label="Показать провинцию ${id} на карте">${id}</button>`;cell.querySelector('button').onclick=()=>{if(!confirmLeaveEdits())return;showMap();emit('map:search',id);};});
    }
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
    if(pendingProvinceId&&table){
      const row=[...table.tBodies[0].rows].find(item=>Number(item.cells[1]?.textContent)===Number(pendingProvinceId));
      if(row){provinceSearchQuery='';host.querySelector('[data-province-search]').value='';host.querySelector('[data-province-search]').dispatchEvent(new Event('input'));row.classList.add('focused-province');requestAnimationFrame(()=>row.scrollIntoView({block:'center',inline:'nearest'}));}
      pendingProvinceId=null;
    }
  }
  if(isAdmin){
    host.querySelector('#state-back').onclick=()=>{if(confirmLeaveEdits())renderStatesContent(host);};
    host.querySelectorAll('[data-state-tab]').forEach(button=>button.onclick=()=>{if(confirmLeaveEdits())renderStatesContent(host,state.id,button.dataset.stateTab);});
    host.querySelector('#state-delete').onclick=async()=>{
      if(!confirm(`Удалить государство «${state.name}»? Его провинции станут нейтральными, назначения игрокам удалятся, маркеры останутся без государства.`))return;
      const button=host.querySelector('#state-delete');button.disabled=true;
      try{await api(`admin/states/${state.id}`,{method:'DELETE',body:'{}'});stateRows=stateRows.filter(row=>row.id!==state.id);categories=categories.filter(c=>!(c.layer==='states'&&c.id===state.id));renderStatesContent(host);emit('map:refresh');showStatus(`Государство «${state.name}» удалено`,3500);}
      catch(error){button.disabled=false;showStatus(error.message,5000);}
    };
  }
}

async function renderColonizationMissions(host,stateId){
  if(!host)return;
  try{
    const data=await colonizationApi('snapshot',stateId);
    if(!host.isConnected)return;
    const missions=data.missions||[];
    const rows=missions.map(m=>`<tr><td>${escape(m.province_name)}</td><td>${m.sea?'Морская':'Сухопутная'}</td><td>${Number(m.elapsed_turns)}/4</td><td>${Math.max(0,Number(m.turns_remaining))}</td><td>${Number(m.recruits_reserved).toLocaleString('ru-RU')}</td><td>${Number(m.upkeep_paid).toLocaleString('ru-RU')} G</td><td>${m.sea?(m.route||[]).map(id=>escape(allProvinces.find(p=>Number(p.id)===Number(id))?.name||id)).join(' → ')||'—':'—'}</td></tr>`).join('');
    const panel=document.createElement('section');panel.className='application-panel colonization-missions';panel.innerHTML=`<h4>Колонизация</h4><p class="hint">Попыток в этом ходу: ${Number(data.attempts_this_turn||0)}/2. При нехватке 1 000 G на очередное содержание миссия срывается и провинция остаётся нейтральной.</p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Провинция</th><th>Тип миссии</th><th>Ход</th><th>Осталось ходов</th><th>Рекруты</th><th>Содержание уплачено</th><th>Морской маршрут</th></tr></thead><tbody>${rows||'<tr><td colspan="7" class="hint">Активных колоний нет.</td></tr>'}</tbody></table></div>`;
    host.append(panel);
  }catch(error){if(host.isConnected){const p=document.createElement('p');p.className='form-message';p.textContent=`Не удалось загрузить колонии: ${error.message}`;host.append(p);}}
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
  try{stateRows=await api('admin/states');if(!host.isConnected||activeMenuSection!=='Государства')return;const pending=pendingStateNavigation;pendingStateNavigation=null;const selected=pending||{stateId:lastAdminStateId,tab:lastAdminStateTab};if(selected.stateId&&stateRows.some(row=>Number(row.id)===Number(selected.stateId)))renderStatesContent(host,selected.stateId,selected.tab);else renderStatesContent(host);}
  catch(error){if(host.isConnected&&activeMenuSection==='Государства')host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

function renderStatesContent(host,selectedId=null,tab='Статистика',create=false){
  if(!host.isConnected)return;
  const state=stateRows.find(row=>row.id===Number(selectedId));
  host.dataset.adminStateId=state?String(state.id):'';
  host.dataset.adminStateTab=tab;
  lastAdminStateId=state?.id||null;
  lastAdminStateTab=tab;
  const nextHash=routeHash('Государства',lastAdminStateId,tab);
  if(location.hash!==nextHash)history.pushState({section:'Государства'},'',nextHash);
  if(state){
    const local=allProvinces.filter(p=>p.kind==='land'&&(Number(p.layers?.states?.id)===state.id||p.occupation===state.name));
    renderStateDetails(host,state,tab,local,true);
    return;
  }
  const pageTitle=$('page-heading')?.querySelector('h1');
  if(pageTitle)pageTitle.textContent='Государство';
  document.title='Государство — Sixième Terre';
  const stateList=stateRows.map(row=>`<button class="state-list-row" type="button" data-open-state="${row.id}"><span class="state-color" style="background:${escape(row.color)}"></span><span>${escape(row.name)}</span><small>${row.players?.length?'Игрок':row.is_npc?'NPC':'Без владельца'} · ${Number(row.province_count)} пров.</small></button>`).join('');
  const principleFields=Object.entries({authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина'}).map(([key,label])=>`<label class="field"><span>${label}</span><select name="${key}" required>${PRINCIPLES[key].map(value=>`<option value="${escape(value)}">${escape(value)}</option>`).join('')}</select></label>`).join('');
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
  updateTopNavigation('map');
  $('app-brand').onclick=()=>{if(confirmLeaveEdits())showMap();};
  document.querySelectorAll('[data-top-view]').forEach(button=>button.onclick=()=>{
    const view=button.dataset.topView;
    if(!confirmLeaveEdits())return;
    if(view==='map')showMap();
    else if(view==='state')renderMenu(user?.role==='admin'?'Государства':lastStateSection);
    else renderMenu(view==='wall'?'Стена':'Правила и механики');
  });
  $('header-profile').onclick=()=>showUtilityPopover('profile');
  $('header-notifications').onclick=()=>showUtilityPopover('notifications');
  $('calendar-toggle').onclick=()=>{closeUtilityPopover();const popover=$('calendar-popover');popover.hidden=!popover.hidden;$('calendar-toggle').setAttribute('aria-expanded',String(!popover.hidden));};
  document.addEventListener('click',event=>{if(!event.target.closest('.turn-badge')){$('calendar-popover').hidden=true;$('calendar-toggle').setAttribute('aria-expanded','false');}if(!event.target.closest('.app-utilities,.utility-popover'))closeUtilityPopover();});
  window.addEventListener('popstate',()=>{const section=sectionFromLocation();if(section==='map')showMap(true);else renderMenu(section,true);});
  for(const[key,[name,icon,side]]of Object.entries(PANELS)){
    const button=document.createElement('button');button.className='dock-button';button.id=`panel-${key}`;button.dataset.panel=key;button.title=name;button.setAttribute('aria-label',name);button.setAttribute('aria-expanded','false');button.innerHTML=`<img src="assets/icons/${icon}.svg" alt="">`;
    if(key==='admin')button.hidden=true;button.onclick=()=>togglePanel(key);$(`${side}-dock`).append(button);
  }
  if(matchMedia('(min-width:768px)').matches){legendOpen=true;$('legend-drawer').hidden=false;updateDockState();queueLayout();}
  $('advance-turn').onclick=async()=>{
    const button=$('advance-turn');if(user?.role!=='admin'||button.disabled)return;
    if(!confirm('Рассчитать налоги, зачислить их в казны государств и перейти на следующий год и ход?'))return;
    button.disabled=true;button.textContent='Расчёт…';
    try{renderCalendar(await api('admin/turn/advance',{method:'POST',body:JSON.stringify({expected_year:gameCalendar.year,expected_turn:gameCalendar.turn})}));void refreshHeaderResources();showStatus('Налоги начислены, содержание армии оплачено, долг обновлён; год и ход увеличены на 1',5000);}
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
let colonizationDraft=null;
function renderCalendar(calendar){gameCalendar={year:Number(calendar.year),turn:Number(calendar.turn)};const season=gameCalendar.turn%2?'Тёплый':'Холодный';const label=`${gameCalendar.year.toLocaleString('ru-RU')} год · Ход ${gameCalendar.turn.toLocaleString('ru-RU')} · ${season}`;$('calendar-label').textContent=label;$('calendar-detail').textContent=`${label} сезон`;}
export function hydrateUI(data){categories=data.categories;allProvinces=data.provinces;provinceAdjacency=data.adjacency||{};mapMarkers=data.markers||[];activeColonies=data.colonies||[];roadsList=data.roads||[];if(data.economy_config){economyDraft=data.economy_config;setEconomyConfig(data.economy_config);}if(legendOpen)renderLegend();emit('map:settings',settings);api('game/calendar').then(renderCalendar).catch(e=>showStatus(e.message,4000));api('auth/me').then(async result=>{await acceptUser(result.user);const section=sectionFromLocation();if(section!=='map')renderMenu(section,true);}).catch(e=>showStatus(e.message,4000));}
let selectionActionRevision=0;
const colonizationMilitaryCache=new Map();
function loadColonizationMilitary(stateId){
  const cached=colonizationMilitaryCache.get(stateId);if(cached&&Date.now()-cached.time<30000)return cached.promise;
  const promise=militaryApi('snapshot',stateId).catch(error=>{colonizationMilitaryCache.delete(stateId);throw error;});
  colonizationMilitaryCache.set(stateId,{time:Date.now(),promise});return promise;
}
window.addEventListener('state:resources-changed',()=>colonizationMilitaryCache.clear());
window.addEventListener('map:selection-changed',e=>{selectedProvince=e.detail||null;selectionActionRevision++;if(colonizationDraft&&Number(colonizationDraft.provinceId)!==Number(selectedProvince?.id)){colonizationDraft=null;$('selection')?.classList.remove('colonization-open');$('colonization-inline')?.remove();}});
window.addEventListener('map:military-data',event=>{visibleGarrisonsByProvince=new Map((event.detail?.garrisons||[]).map(item=>[Number(item.province_id),item]));});
window.addEventListener('map:garrison-info',event=>{
  const details=$('selection-details');if(!details)return;
  details.querySelector('.province-garrison-summary')?.remove();
  const item=event.detail;if(!item||$('selection')?.hidden)return;
  const section=document.createElement('section');section.className='province-garrison-summary';
  const title=document.createElement('h3');title.textContent='Гарнизон';section.append(title);
  const fortLabels=['Нет','Форт','Крепость I','Крепость II','Крепость III'],wallLabels=['Нет','Городские стены I','Городские стены II','Городские стены III'];
  const levels=document.createElement('p');levels.textContent=`Укрепления: ${fortLabels[Number(item.fort_level)||0]||'Укрепление'}${Number(item.wall_level)>0?` · ${wallLabels[Number(item.wall_level)]||'Стены'}`:''}`;section.append(levels);
  const units=item.units||[];
  if(units.length){const list=document.createElement('ul');for(const unit of units){const row=document.createElement('li');row.textContent=`${unit.name} × ${Number(unit.quantity||0).toLocaleString('ru-RU')}`;list.append(row);}section.append(list);}
  else{const empty=document.createElement('p');empty.className='hint';empty.textContent='Войск нет.';section.append(empty);}
  const total=document.createElement('p');total.className='province-garrison-total';total.textContent=`Всего: ${Number(item.total_quantity||units.reduce((sum,unit)=>sum+Number(unit.quantity||0),0)).toLocaleString('ru-RU')}`;section.append(total);
  details.append(section);
});
window.addEventListener('ui:open-diplomacy-state',event=>{const stateId=Number(event.detail?.stateId);if(!stateId)return;pendingDiplomacyStateId=stateId;if(user?.role==='admin'){lastAdminStateId=stateId;pendingStateNavigation={stateId,tab:'Дипломатия'};renderMenu('Государства');}else renderMenu('Дипломатия');});
window.addEventListener('map:selection-changed',e=>{void renderSelectedPortAction(e.detail,selectionActionRevision);});
window.addEventListener('map:selection-changed',e=>{void renderSelectedColonization(e.detail,selectionActionRevision);});
window.addEventListener('map:selection-changed',e=>{renderSelectedGarrisonAction(e.detail,selectionActionRevision);});
const fortLabels=['Нет','Форт','Крепость I','Крепость II','Крепость III'];
const wallLabels=['Нет','Городские стены I','Городские стены II','Городские стены III'];
const fortCosts=[0,10000,30000,60000,120000],wallCosts=[0,50000,150000,300000];
const fortCapacity=[0,100,300,800,1300],wallCapacity=[0,500,1000,2000];
const fortUpkeep=[0,100,200,300,400],wallUpkeep=[0,300,500,700];
let fortPlacementUI=null;
function closeFortDialog(){document.querySelector('.fort-build-dialog')?.remove();}
function openFortDialog(province,stateId,site,kind){
  closeFortDialog();
  const currentLevel=Number(kind==='fort'?site.fort_level:site.wall_level)||0;
  const labels=kind==='fort'?fortLabels:wallLabels,costs=kind==='fort'?fortCosts:wallCosts,capacity=kind==='fort'?fortCapacity:wallCapacity,upkeep=kind==='fort'?fortUpkeep:wallUpkeep;
  const maxLevel=kind==='fort'?(site.neutral?1:4):3;
  const choices=Array.from({length:maxLevel-currentLevel},(_,i)=>i+currentLevel+1);
  if(!choices.length){showStatus('Максимальный уровень уже достигнут',3000);return;}
  const dialog=document.createElement('section');dialog.className='surface fort-build-dialog';dialog.setAttribute('role','dialog');dialog.setAttribute('aria-modal','true');dialog.setAttribute('aria-label',kind==='fort'?'Построить или улучшить крепость':'Улучшить городские стены');
  dialog.innerHTML=`<header><h2>${kind==='fort'?'Крепость':'Городские стены'} · ${escape(province.name)}</h2><button type="button" data-fort-close aria-label="Закрыть">×</button></header><p>Текущий уровень: ${escape(labels[currentLevel])}. Выберите уровень: стоимость улучшения учитывает уже построенное укрепление.</p><label class="field"><span>Уровень</span><select data-fort-level>${choices.map(level=>`<option value="${level}">${escape(labels[level])}</option>`).join('')}</select></label><p data-fort-details></p><div class="fort-build-actions"><button type="button" class="primary" data-fort-submit>Построить</button><button type="button" data-fort-close>Отмена</button></div>`;
  document.body.append(dialog);
  const select=dialog.querySelector('[data-fort-level]'),details=dialog.querySelector('[data-fort-details]');
  const update=()=>{const level=Number(select.value),turns=(kind==='fort'?level===4:level===3)?2:1;details.textContent=`Цена: ${(costs[level]-costs[currentLevel]).toLocaleString('ru-RU')} G · Вместимость: +${capacity[level].toLocaleString('ru-RU')} · Содержание: ${upkeep[level]} G/ход · Строительство: ${turns} ход.`;};
  select.onchange=update;update();dialog.querySelectorAll('[data-fort-close]').forEach(button=>button.onclick=closeFortDialog);
  dialog.querySelector('[data-fort-submit]').onclick=async()=>{const level=Number(select.value),cost=costs[level]-costs[currentLevel];if(!confirm(`Построить ${labels[level]} в провинции «${province.name}» за ${cost.toLocaleString('ru-RU')} G?`))return;
    if(kind==='fort'&&currentLevel===0){fortPlacementUI={provinceId:Number(province.id),stateId,level};closeFortDialog();closeMarkerPopover();emit('map:place-fort',{province_id:Number(province.id),state_id:stateId,level});showStatus('Укажите точку крепости внутри провинции. Esc — отмена.',0);return;}
    const button=dialog.querySelector('[data-fort-submit]');button.disabled=true;try{await garrisonApi('build',stateId,Number(province.id),{kind,level});closeFortDialog();showStatus('Строительство началось',3000);emit('map:refresh');window.dispatchEvent(new Event('state:resources-changed'));}catch(error){button.disabled=false;showStatus(error.message,5000);}};
  select.focus();
}
function renderSelectedGarrisonAction(province,revision){
  if(province?.kind!=='land'||!user)return;
  const stateId=Number(user.role==='admin'?lastAdminStateId:user.state_ids?.[0]);if(!stateId)return;
  const owned=Number(province.layers?.states?.id)===stateId,neutral=province.layers?.states?.id==null;
  const adjacent=(provinceAdjacency?.[province.id]||[]).some(id=>allProvinces.some(p=>Number(p.id)===Number(id)&&p.kind==='land'&&Number(p.layers?.states?.id)===stateId));
  if(!owned&&!(neutral&&adjacent&&!activeColonies.some(item=>Number(item.province_id)===Number(province.id))))return;
  if(mapMarkers.some(marker=>Number(marker.province_id)===Number(province.id)&&['fortress','capital'].includes(marker.type)))return;
  const details=$('selection-details');if(!details||$('selection')?.hidden||revision!==selectionActionRevision)return;
  addFortBuildButton(province,stateId,details,owned);
}
function addFortBuildButton(province,stateId,details,owned){
  if(details.querySelector('[data-build-fort]')||mapMarkers.some(marker=>Number(marker.province_id)===Number(province.id)&&['fortress','capital'].includes(marker.type)))return;
  const button=document.createElement('button');button.type='button';button.className='selection-open-data';button.dataset.buildFort='';button.textContent='Построить Крепость';button.onclick=async()=>{button.disabled=true;
    try{const info=await garrisonApi('info',null,Number(province.id));
      if(!info||Number(info.fort_level)>0||info.building?.some(project=>project.kind==='fort'))throw new Error('Крепость уже построена или строится');
      openFortDialog(province,stateId,{fort_level:info.fort_level,wall_level:info.wall_level,neutral:!owned,owned},'fort');
    }catch(error){showStatus(error.message,4000);}finally{button.disabled=false;}};
  const colonyButton=details.querySelector('[data-colonize-land]')||details.querySelector('[data-colonize-sea]');if(colonyButton)colonyButton.after(button);else details.prepend(button);
}
function seaColonizationReachable(provinceId,stateId){
  const byId=new Map(allProvinces.map(province=>[Number(province.id),province]));
  const targetSeas=new Set((provinceAdjacency?.[provinceId]||[]).map(Number).filter(id=>byId.get(id)?.kind==='sea'));
  if(!targetSeas.size)return false;
  const queue=[],visited=new Set();
  for(const province of allProvinces){if(province.kind!=='land'||Number(province.layers?.states?.id)!==stateId)continue;
    for(const next of provinceAdjacency?.[province.id]||[]){const id=Number(next);if(byId.get(id)?.kind==='sea'&&!visited.has(id)){visited.add(id);queue.push([id,1]);}}
  }
  for(let index=0;index<queue.length;index++){
    const [id,depth]=queue[index];if(targetSeas.has(id))return true;if(depth>=40)continue;
    for(const next of provinceAdjacency?.[id]||[]){const nextId=Number(next);if(byId.get(nextId)?.kind==='sea'&&!visited.has(nextId)){visited.add(nextId);queue.push([nextId,depth+1]);}}
  }
  return false;
}
window.addEventListener('map:fort-placement-cancelled',()=>{fortPlacementUI=null;});
window.addEventListener('map:fort-location-selected',async event=>{const placement=fortPlacementUI;fortPlacementUI=null;if(!placement)return;
  try{await garrisonApi('build',placement.stateId,placement.provinceId,{kind:'fort',level:placement.level,x:Number(event.detail.x),y:Number(event.detail.y)});showStatus('Строительство крепости началось',3500);emit('map:refresh');window.dispatchEvent(new Event('state:resources-changed'));}
  catch(error){showStatus(error.message,5000);}
});
async function renderSelectedColonization(province,revision){
  if(province?.kind!=='land'||!user)return;
  const existing=activeColonies.find(item=>Number(item.province_id)===Number(province.id));
  if(existing){const details=$('selection-details');if(details&&!$('selection').hidden){const field=document.createElement('div');field.className='province-field';field.textContent=`Колония государства «${existing.state_name}»`;details.append(field);}return;}
  const stateId=Number(user.role==='admin'?lastAdminStateId:user.state_ids?.[0]);
  if(!stateId||province.layers?.states?.id!=null)return;
  const details=$('selection-details');if(!details||$('selection').hidden)return;
  const neighbors=(provinceAdjacency?.[province.id]||[]).map(Number);
  const adjacent=neighbors.some(id=>allProvinces.some(p=>Number(p.id)===id&&p.kind==='land'&&Number(p.layers?.states?.id)===stateId));
  const coastal=neighbors.some(id=>allProvinces.some(p=>Number(p.id)===id&&p.kind==='sea'));
  const loadMilitary=()=>loadColonizationMilitary(stateId);
  if(adjacent){const button=document.createElement('button');button.type='button';button.className='selection-open-data';button.dataset.colonizeLand='';button.textContent='Колонизировать';button.onclick=async()=>{button.disabled=true;try{openColonizationDialog(province,stateId,await loadMilitary(),false);}catch(error){showStatus(error.message,4000);}finally{button.disabled=false;}};details.prepend(button);}
  if(!coastal)return;
  try{const military=await loadMilitary();
    if(revision!==selectionActionRevision||Number(selectedProvince?.id)!==Number(province.id)||!$('selection')||$('selection').hidden)return;
    const fleets=(military.formations||[]).filter(f=>f.domain==='naval'&&f.active&&f.leader_id&&(f.units||[]).reduce((sum,u)=>sum+Number(u.capacity||0)*Number(u.quantity||0),0)>=50&&!(f.units||[]).some(u=>Number(u.capacity)>0&&Number(u.quantity)>0&&u.locked));
    if(fleets.length&&seaColonizationReachable(province.id,stateId)){const button=document.createElement('button');button.type='button';button.className='selection-open-data';button.dataset.colonizeSea='';button.textContent='Морская колонизация';button.onclick=()=>openColonizationDialog(province,stateId,military,true);details.insertBefore(button,details.querySelector('[data-colonize-land]')||details.querySelector('[data-build-fort]')||details.firstChild);
      if(!adjacent&&!mapMarkers.some(marker=>Number(marker.province_id)===Number(province.id)&&marker.type==='fortress'))addFortBuildButton(province,stateId,details,false);}
  }catch(error){showStatus(error.message,4000);}
}
function openColonizationDialog(province,stateId,military,sea){
  if(colonizationDraft&&Number(colonizationDraft.provinceId)===Number(province.id)&&colonizationDraft.sea===sea){colonizationDraft=null;$('selection').classList.remove('colonization-open');$('colonization-inline')?.remove();window.dispatchEvent(new CustomEvent('colonization:route-pick',{detail:{active:false}}));return;}
  colonizationDraft={provinceId:Number(province.id),provinceName:province.name,stateId,sea,fleetId:null,route:[],military};
  const base=sea?2400:1200;
  const fleetOptions=(military.formations||[]).filter(f=>f.domain==='naval'&&f.active&&f.leader_id).map(f=>`<option value="${Number(f.id)}">${escape(f.name)} · ${escape((military.leaders||[]).find(l=>Number(l.id)===Number(f.leader_id))?.name||'Адмирал')} · вместимость ${(f.units||[]).reduce((sum,u)=>sum+Number(u.capacity||0)*Number(u.quantity||0),0).toLocaleString('ru-RU')}</option>`).join('');
  const selection=$('selection');selection.classList.add('colonization-open');$('colonization-inline')?.remove();
  const inline=document.createElement('aside');inline.id='colonization-inline';inline.className='colonization-inline';inline.innerHTML=`<div class="colonization-inline-heading"><strong>${sea?'Морская колонизация':'Колонизация'}</strong><button type="button" class="colonization-inline-close" aria-label="Закрыть">×</button></div><form id="colonization-form" class="stack"><p>Цель: <strong>${escape(province.name)}</strong>. Минимум ${base.toLocaleString('ru-RU')} G и 50 рекрутов. Дополнительные 1 000 G и 100 рекрутов дают по +5 к броску, максимум +15 за каждый источник.</p>${sea?`<label class="field"><span>Флотилия с адмиралом</span><select name="fleet_id" required>${fleetOptions}</select></label><p class="hint" data-colony-route>Маршрут пока не выбран. Нажмите «Выбрать маршрут», затем кликайте морские провинции от собственного берега к цели.</p><button type="button" data-colony-route-start>Выбрать маршрут</button>`:''}<label class="field"><span>Золото</span><input name="gold" type="number" min="${base}" step="1" value="${base}" required></label><label class="field"><span>Рекруты</span><input name="recruits" type="number" min="50" max="${Math.max(50,Number(military.recruits||0))}" step="1" value="50" required></label><p class="hint" data-colony-preview></p><p class="hint">При успехе миссия длится 4 хода, включая текущий. В следующие 3 хода содержание — 1 000 G за ход. Если в казне не хватает 1 000 G, миссия срывается, провинция снова становится нейтральной.</p><button type="submit" class="primary">Отправить миссию</button></form>`;
  selection.append(inline);
  inline.querySelector('.colonization-inline-close').onclick=()=>{colonizationDraft=null;selection.classList.remove('colonization-open');inline.remove();window.dispatchEvent(new CustomEvent('colonization:route-pick',{detail:{active:false}}));};
  const form=inline.querySelector('#colonization-form');
  form.elements.fleet_id?.addEventListener('change',()=>{colonizationDraft.fleetId=Number(form.elements.fleet_id.value);});
  const preview=()=>{const gold=Number(form.elements.gold.value)||0,recruits=Number(form.elements.recruits.value)||0,goldBonus=Math.min(15,Math.max(0,Math.floor((gold-base)/1000)*5)),recruitBonus=Math.min(15,Math.max(0,Math.floor((recruits-50)/100)*5)),penalty=colonizationDraft.route.reduce((sum,id)=>sum+((provinceAdjacency[id]||[]).some(n=>allProvinces.some(p=>Number(p.id)===Number(n)&&p.kind==='land'))?2:5),0);form.querySelector('[data-colony-preview]').textContent=`Стоимость: ${gold.toLocaleString('ru-RU')} G · рекруты: ${recruits.toLocaleString('ru-RU')} · бонусы: +${goldBonus} за золото и +${recruitBonus} за рекрутов${sea?` · штраф маршрута: −${penalty}`:''}.`;};
  form.elements.gold.addEventListener('input',preview);form.elements.recruits.addEventListener('input',preview);preview();
  const start=form.querySelector('[data-colony-route-start]');start?.addEventListener('click',()=>{colonizationDraft.route=[];window.dispatchEvent(new CustomEvent('colonization:route-pick',{detail:{active:true,clear:true}}));showStatus('Выберите морской маршрут: начинайте у своей суши и завершите у цели.',0);});
  form.addEventListener('submit',async event=>{event.preventDefault();const data=new FormData(form);if(sea&&!colonizationDraft.route.length){showStatus('Сначала выберите маршрут на карте.',4000);return;}if(sea&&!colonizationDraft.fleetId)colonizationDraft.fleetId=Number(data.get('fleet_id'));const button=form.querySelector('[type="submit"]');button.disabled=true;try{const result=await colonizationApi('attempt',stateId,{province_id:province.id,sea,gold:Number(data.get('gold')),recruits:Number(data.get('recruits')),fleet_id:colonizationDraft.fleetId,route:colonizationDraft.route});selection.classList.remove('colonization-open');inline.remove();colonizationDraft=null;showStatus(result.success?`Успех! Итог ${result.result}. Началась колонизация на 4 хода.`:`Провал. Итог ${result.result}; потери рекрутов: ${Number(result.recruits_lost).toLocaleString('ru-RU')}${result.catastrophic?'. Флотилия потеряна.':''}`,6500);window.dispatchEvent(new Event('state:resources-changed'));window.dispatchEvent(new Event('map:refresh'));}catch(error){button.disabled=false;showStatus(error.message,5000);}});
}
window.addEventListener('colonization:route-province-picked',event=>{
  if(!colonizationDraft?.sea)return;const p=event.detail,id=Number(p?.id),route=colonizationDraft.route,last=route.at(-1);
  if(!p||p.kind!=='sea'){showStatus('Морской маршрут должен проходить по морским провинциям.',3000);return;}
  if(route.includes(id)){showStatus('Провинция уже есть в маршруте.',2500);return;}
  if(!last){const fromOwnLand=(provinceAdjacency[id]||[]).some(n=>allProvinces.some(land=>Number(land.id)===Number(n)&&land.kind==='land'&&Number(land.layers?.states?.id)===colonizationDraft.stateId));if(!fromOwnLand){showStatus('Начните маршрут с моря, соседнего с вашей сушей.',3500);return;}}
  else if(!(provinceAdjacency[last]||[]).some(n=>Number(n)===id)){showStatus('Следующая морская провинция должна быть соседней.',3000);return;}
  if(route.length>=40){showStatus('Морской маршрут ограничен 40 провинциями.',3000);return;}
  route.push(id);window.dispatchEvent(new CustomEvent('colonization:route-progress',{detail:{ids:[...route]}}));
  const reachesTarget=(provinceAdjacency[id]||[]).some(n=>Number(n)===colonizationDraft.provinceId);
  const label=$('colonization-inline')?.querySelector('[data-colony-route]');if(label)label.textContent=`Маршрут: ${route.length} мор. пров. · штраф −${route.reduce((sum,seaId)=>sum+((provinceAdjacency[seaId]||[]).some(n=>allProvinces.some(p=>Number(p.id)===Number(n)&&p.kind==='land'))?2:5),0)} к броску${reachesTarget?' · цель достигнута':''}`;
  const preview=$('colonization-inline')?.querySelector('[data-colony-preview]');if(preview){const form=$('colonization-inline').querySelector('#colonization-form'),base=2400,gold=Number(form.elements.gold.value)||0,recruits=Number(form.elements.recruits.value)||0,goldBonus=Math.min(15,Math.max(0,Math.floor((gold-base)/1000)*5)),recruitBonus=Math.min(15,Math.max(0,Math.floor((recruits-50)/100)*5));preview.textContent=`Стоимость: ${gold.toLocaleString('ru-RU')} G · рекруты: ${recruits.toLocaleString('ru-RU')} · бонусы: +${goldBonus} за золото и +${recruitBonus} за рекрутов · штраф маршрута −${route.reduce((sum,seaId)=>sum+((provinceAdjacency[seaId]||[]).some(n=>allProvinces.some(p=>Number(p.id)===Number(n)&&p.kind==='land'))?2:5),0)}.`;}
  if(reachesTarget){window.dispatchEvent(new CustomEvent('colonization:route-pick',{detail:{active:false}}));showStatus('Маршрут завершён у цели.',2500);}
  else showStatus(`Морская провинция добавлена (${route.length}). Выберите следующую соседнюю.`,0);
});
window.addEventListener('colonization:route-cancelled',()=>{if(colonizationDraft)showStatus('Выбор маршрута отменён.',2500);});
async function renderSelectedPortAction(province,revision){
  if(province?.kind!=='sea'||!user)return;
  const stateId=Number(user.role==='admin'?lastAdminStateId:user.state_ids?.[0]);
  if(!stateId)return;
  const hasPort=mapMarkers.some(marker=>Number(marker.province_id)===Number(province.id)&&marker.type==='port');
  const neighbors=provinceAdjacency?.[province.id]||[];
  const hasControlledShore=neighbors.some(id=>{const shore=allProvinces.find(item=>Number(item.id)===Number(id));return shore?.kind==='land'&&Number(shore.layers?.states?.id)===stateId;});
  if(hasPort||!hasControlledShore)return;
  try{
    const snapshot=await militaryApi('snapshot',stateId);
    if(revision!==selectionActionRevision||Number(selectedProvince?.id)!==Number(province.id)||Number(snapshot.crown)<10000)return;
    const details=$('selection-details');if(!details||$('selection').hidden)return;
    const button=document.createElement('button');button.type='button';button.className='selection-open-data';button.textContent='Выбрать место для порта · 10 000 G';
    button.onclick=()=>{button.disabled=true;cancel.hidden=false;activePortPlacementUI={button,cancel};emit('map:place-port',{province_id:Number(province.id),state_id:stateId});showStatus('Укажите точку порта на карте. Нажмите Esc для отмены.',0);};
    const cancel=document.createElement('button');cancel.type='button';cancel.className='selection-open-data';cancel.textContent='Отмена';cancel.hidden=true;
    details.append(button,cancel);
    cancel.onclick=()=>{emit('map:place-port',null);button.disabled=false;cancel.hidden=true;activePortPlacementUI=null;};
  }catch(error){showStatus(error.message,4000);}
}
window.addEventListener('map:port-placement-cancelled',()=>{if(!activePortPlacementUI)return;activePortPlacementUI.button.disabled=false;activePortPlacementUI.cancel.hidden=true;activePortPlacementUI=null;});
window.addEventListener('map:port-location-selected',async event=>{
  const {province_id,x,y,state_id}=event.detail||{};
  const placementUI=activePortPlacementUI;activePortPlacementUI=null;if(placementUI)placementUI.cancel.hidden=true;
  try{await militaryApi('build_port',Number(state_id),{province_id:Number(province_id),x:Number(x),y:Number(y)});showStatus('Строительство порта началось · 1 ход',3000);window.dispatchEvent(new Event('state:resources-changed'));emit('map:refresh');}
  catch(error){if(placementUI)placementUI.button.disabled=false;showStatus(error.message,5000);}
});
window.addEventListener('ui:open-province',e=>{
  const id=Number(e.detail?.id),stateId=Number(e.detail?.stateId);
  if(!id||!stateId)return;
  if(user?.role==='admin'){lastAdminStateId=stateId;pendingStateNavigation={stateId,tab:'Провинции'};pendingProvinceId=id;renderMenu('Государства');}
  else if(user?.state_ids?.includes(stateId)){pendingProvinceId=id;renderMenu('Провинции');}
});
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
window.addEventListener('map:refreshed',e=>{categories=e.detail.categories;allProvinces=e.detail.provinces;provinceAdjacency=e.detail.adjacency||provinceAdjacency;mapMarkers=e.detail.markers||[];activeColonies=e.detail.colonies||[];tradeAvailability={};roadsList=e.detail.roads||[];if(e.detail.economy_config){setEconomyConfig(e.detail.economy_config);if(!economyDirty)economyDraft=e.detail.economy_config;}});
window.addEventListener('state:resources-changed',()=>{void refreshHeaderResources();});
window.addEventListener('roads:progress',e=>{roadInfo=e.detail;if(current==='admin'&&adminTool==='roads')renderDrawer();});
window.addEventListener('roads:saved',e=>{roadsList.push(e.detail);if(current==='admin'&&adminTool==='roads')renderDrawer();});
let markerPopover=null;
function closeMarkerPopover(){markerPopover?.remove();markerPopover=null;}
window.addEventListener('map:close-marker-popup',closeMarkerPopover);
let militaryMapPopover=null;
function closeMilitaryMapPopover(){militaryMapPopover?.remove();militaryMapPopover=null;}
window.addEventListener('map:close-military-popup',closeMilitaryMapPopover);
window.addEventListener('map:military-selected',event=>{
  closeMilitaryMapPopover();const item=event.detail;if(!item)return;
  const construction=item.token_type==='construction',garrison=item.token_type==='garrison',fleet=item.token_type==='fleet',title=construction?`${item.name} строится · ${item.province_name}`:garrison?`Гарнизон · ${item.province_name}`:`${fleet?'Флотилия':'Армия'} · ${item.name||'Без названия'}`;
  const box=document.createElement('section');box.className='surface military-map-popover';box.setAttribute('role','dialog');box.setAttribute('aria-label',construction?'Строительство объекта':'Сведения о военном формировании');
  const header=document.createElement('header'),heading=document.createElement('h2');heading.textContent=title;const close=document.createElement('button');close.type='button';close.className='icon-button';close.setAttribute('aria-label','Закрыть');close.textContent='×';close.onclick=closeMilitaryMapPopover;header.append(heading,close);box.append(header);
  const body=document.createElement('div');body.className='military-map-popover-content';
  const owner=document.createElement('p');owner.className='military-map-owner';const swatch=document.createElement('i');swatch.className='legend-swatch';swatch.style.background=/^#[0-9a-f]{6}$/i.test(item.state_color)?item.state_color:'#78806f';const stateName=document.createElement('strong');stateName.textContent=item.state_name||'Государство не указано';owner.append(swatch,stateName);body.append(owner);
  if(construction){const status=document.createElement('p');status.textContent=`Объект находится в стадии строительства. Осталось ходов: ${Number(item.turns_remaining||0)}.`;body.append(status);}
  else{
    if(garrison){const fort=['Нет','Форт','Крепость I','Крепость II','Крепость III'][Number(item.fort_level)||0]||'Укрепление';const wall=['Нет','Стены I','Стены II','Стены III'][Number(item.wall_level)||0]||'Стены';const structures=document.createElement('p');structures.textContent=`Укрепления: ${fort}${wall==='Нет'?'':` · ${wall}`}`;body.append(structures);}
    else if(item.leader_name){const commander=document.createElement('p');commander.textContent=`${fleet?'Адмирал':'Генерал'}: ${item.leader_name}`;body.append(commander);}
    const units=item.units||[];if(units.length){const list=document.createElement('ul');for(const unit of units){const row=document.createElement('li');row.textContent=`${unit.name} × ${Number(unit.quantity||0).toLocaleString('ru-RU')}`;list.append(row);}body.append(list);}else{const empty=document.createElement('p');empty.className='hint';empty.textContent='Состав не указан.';body.append(empty);}
    const total=document.createElement('p');total.className='military-map-total';total.textContent=`Всего: ${Number(item.total_quantity||units.reduce((sum,unit)=>sum+Number(unit.quantity||0),0)).toLocaleString('ru-RU')}`;body.append(total);
    if(item.movement_order){const routeStatus=document.createElement('p');routeStatus.className='hint';routeStatus.textContent=`Маршрут задан · точек осталось: ${Math.max(0,(item.movement_order.route?.length||0)-Number(item.movement_order.next_index||1))}${item.movement_order.stop_reason?` · остановка: ${item.movement_order.stop_reason}`:''}`;body.append(routeStatus);}
    if(!garrison){
      if(user&&(user.role==='admin'||user.state_ids?.map(Number).includes(Number(item.state_id)))){
        const actions=document.createElement('div');actions.className='military-map-actions';
        if(!fleet||item.is_port||item.movement_order){const move=document.createElement('button');move.type='button';move.textContent=item.movement_order?'Изменить маршрут':fleet?'Задать морской маршрут':'Задать движение';move.onclick=()=>{emit('map:movement-start',item);closeMilitaryMapPopover();};actions.append(move);}
        else{const portHint=document.createElement('p');portHint.className='hint';portHint.textContent='Флотилия не в доступном порту. Прикажите ей пройти до порта, чтобы снова изменить курс.';body.append(portHint);}
        if(item.movement_order&&(!fleet||item.is_port)){const cancel=document.createElement('button');cancel.type='button';cancel.textContent='Отменить маршрут';cancel.onclick=async()=>{cancel.disabled=true;try{await militaryMovementApi('cancel',Number(item.id));emit('map:refresh');closeMilitaryMapPopover();showStatus('Приказ движения отменён',3000);}catch(error){cancel.disabled=false;showStatus(error.message,5000);}};actions.append(cancel);}
        body.append(actions);
      }
    }
  }
  box.append(body);document.body.append(box);
  if(matchMedia('(max-width:767px)').matches){box.style.left='8px';box.style.right='8px';box.style.bottom='8px';box.style.top='auto';}
  else{const rect=box.getBoundingClientRect(),gap=12,margin=8;let left=Number(item.screenX)+gap,top=Number(item.screenY)+gap;if(left+rect.width>innerWidth-margin)left=Number(item.screenX)-rect.width-gap;if(top+rect.height>innerHeight-margin)top=innerHeight-rect.height-margin;box.style.left=`${Math.max(margin,Math.min(innerWidth-rect.width-margin,left))}px`;box.style.top=`${Math.max(margin,Math.min(innerHeight-rect.height-margin,top))}px`;}
  militaryMapPopover=box;
});
window.addEventListener('map:movement-progress',event=>{
  const {route=[],formation,forecast}=event.detail||{};let panel=document.getElementById('military-movement-panel');
  if(!route.length){panel?.remove();return;}
  if(!panel){panel=document.createElement('section');panel.id='military-movement-panel';panel.className='surface military-movement-panel';document.body.append(panel);}
  const naval=formation?.domain==='naval',unit=naval?'флотилии':'армии',forecastLines=[];
  panel.setAttribute('aria-label',`Маршрут ${unit}`);
  if(forecast){
    forecastLines.push(`Путь: ${forecast.distanceKm.toLocaleString('ru-RU',{maximumFractionDigits:1})} км · стоимость марша: ${forecast.cost.toLocaleString('ru-RU',{maximumFractionDigits:1})} / ${forecast.budget.toLocaleString('ru-RU',{maximumFractionDigits:0})} км за текущий ход`);
    forecastLines.push(`Оценка: около ${forecast.turns} ${forecast.turns===1?'хода':'ходов'}${forecast.terrains.length?` · местность: ${forecast.terrains.join(', ')}`:''}${forecast.weathers.length?` · погода: ${forecast.weathers.join(', ')}`:''}`);
    if(naval)forecastLines.push(forecast.ports?'Флот завершит путь в провинции с портом; сервер проверит право базирования.':'Нужно закончить маршрут в провинции с портом.');
    if(forecast.unknown)forecastLines.push(`Условия ${forecast.unknown} участков неизвестны; прогноз для них приблизительный.`);
    if(forecast.stop)forecastLines.push(`Остановка: ${forecast.stop.reason}${forecast.stop.name?` (${forecast.stop.name})`:''}`);
  }
  const forecastOpen=panel.querySelector('.military-movement-details')?.open??!matchMedia('(max-width:760px)').matches;
  panel.innerHTML=`<strong>Маршрут ${unit}</strong><span>Точек: ${route.length}</span><details class="military-movement-details" ${forecastOpen?'open':''}><summary>Прогноз движения</summary><div class="military-movement-forecast">${forecastLines.map(line=>`<span>${escape(line)}</span>`).join('')}</div></details><div><button type="button" data-move-submit ${route.length<2?'disabled':''}>Отправить приказ</button><button type="button" data-move-cancel>Отмена</button></div>`;
  panel.querySelector('[data-move-submit]').onclick=()=>emit('map:movement-submit');panel.querySelector('[data-move-cancel]').onclick=()=>emit('map:movement-clear');
});
window.addEventListener('map:movement-cancelled',()=>{document.getElementById('military-movement-panel')?.remove();showStatus('Построение маршрута отменено',2500);});
window.addEventListener('map:movement-ready',async event=>{
  const button=document.querySelector('[data-move-submit]');if(button)button.disabled=true;
  try{const {formation,route}=event.detail;await militaryMovementApi('set_order',Number(formation.id),{route});emit('map:movement-clear');emit('map:refresh');showStatus('Приказ движения сохранён. Перемещение начнётся при расчёте следующего хода.',4500);}
  catch(error){if(button)button.disabled=false;emit('map:movement-submit-failed');showStatus(error.message,6000);}
});
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
  closeMarkerPopover();
  const marker=event.detail,box=document.createElement('section');box.className='surface marker-popover';box.setAttribute('role','dialog');box.setAttribute('aria-label','Информация о маркере');
  const header=document.createElement('header'),title=document.createElement('h2');title.textContent=`${MARKERS[marker.type]||marker.type}: ${marker.name}`;
  const close=document.createElement('button');close.type='button';close.className='icon-button';close.textContent='×';close.setAttribute('aria-label','Закрыть');close.onclick=closeMarkerPopover;header.append(title,close);box.append(header);
  const content=document.createElement('div');content.className='marker-popover-content';
  for(const [label,value] of [['Название',marker.name],['Тип',MARKERS[marker.type]||marker.type],['Государство',marker.state_name||'—'],['ID провинции',marker.province_id],['Координаты',`${Number(marker.x).toFixed(1)}, ${Number(marker.y).toFixed(1)}`]]){const row=document.createElement('p');row.textContent=`${label}: ${value}`;content.append(row);}
  const markerGarrison=visibleGarrisonsByProvince.get(Number(marker.province_id));
  if(markerGarrison){const fortNames=['Нет','Форт','Крепость I','Крепость II','Крепость III'],wallNames=['Нет','Городские стены I','Городские стены II','Городские стены III'];const section=document.createElement('section');section.className='province-garrison-summary';const heading=document.createElement('h3');heading.textContent='Гарнизон';section.append(heading);const levels=document.createElement('p');levels.textContent=`Укрепления: ${fortNames[Number(markerGarrison.fort_level)||0]||'Укрепление'}${Number(markerGarrison.wall_level)>0?` · ${wallNames[Number(markerGarrison.wall_level)]||'Стены'}`:''}`;section.append(levels);const units=markerGarrison.units||[];if(units.length){const list=document.createElement('ul');for(const unit of units){const row=document.createElement('li');row.textContent=`${unit.name} × ${Number(unit.quantity||0).toLocaleString('ru-RU')}`;list.append(row);}section.append(list);}const total=document.createElement('p');total.className='province-garrison-total';total.textContent=`Всего: ${Number(markerGarrison.total_quantity||0).toLocaleString('ru-RU')}`;section.append(total);content.append(section);}
  if(['capital','city','fortress'].includes(marker.type)){
    const levels=document.createElement('p');levels.textContent='Укрепления: загружаю…';content.append(levels);
    void garrisonApi('info',null,Number(marker.province_id)).then(info=>{
      if(!box.isConnected||!info)return;
      const forts=['нет','Форт','Крепость I','Крепость II','Крепость III'];
      const walls=['нет','Городские стены I','Городские стены II','Городские стены III'];
      levels.textContent=`Крепость: ${forts[Number(info.fort_level)]||'нет'} · Стены: ${walls[Number(info.wall_level)]||'нет'} · Лимит гарнизона: ${Number(info.capacity||0).toLocaleString('ru-RU')}`;
      if(info.building?.length){const build=document.createElement('p');build.textContent=`Строится: ${info.building.map(item=>`${item.kind==='fort'?forts[item.target_level]:walls[item.target_level]} (${item.turns_remaining} ход.)`).join(', ')}`;content.append(build);}
      const stateId=Number(user?.role==='admin'?lastAdminStateId:user?.state_ids?.[0]);
      if(!stateId)return;
      void garrisonApi('snapshot',stateId).then(snapshot=>{
        if(!box.isConnected)return;
        const site=(snapshot.provinces||[]).find(item=>Number(item.id)===Number(marker.province_id));
        const province=allProvinces.find(item=>Number(item.id)===Number(marker.province_id));
        if(!site||!province||site.projects?.length)return;
        const actions=document.createElement('div');actions.className='marker-fort-actions';
        if(Number(site.fort_level)>0&&Number(site.fort_level)<4&&site.owned){const button=document.createElement('button');button.type='button';button.textContent='Улучшить Крепость';button.onclick=()=>openFortDialog(province,stateId,site,'fort');actions.append(button);}
        if(site.owned&&['capital','city'].includes(marker.type)&&Number(site.wall_level)<3){const button=document.createElement('button');button.type='button';button.textContent=Number(site.wall_level)>0?'Улучшить Стены':'Построить Стены';button.onclick=()=>openFortDialog(province,stateId,site,'wall');actions.append(button);}
        if(actions.childElementCount)box.append(actions);
      }).catch(()=>{});
    }).catch(()=>{if(box.isConnected)levels.textContent='Уровни укреплений недоступны';});
  }
  box.append(content);
  const renameForm=document.createElement('form');renameForm.className='marker-rename-form';
  const nameInput=document.createElement('input');nameInput.type='text';nameInput.maxLength=120;nameInput.required=true;nameInput.value=marker.name;nameInput.setAttribute('aria-label','Название маркера');
  const save=document.createElement('button');save.type='submit';save.textContent='Сохранить название';renameForm.append(nameInput,save);
  renameForm.onsubmit=async event=>{event.preventDefault();const name=nameInput.value.trim();if(!name){nameInput.focus();return;}save.disabled=true;try{const updated=await api(`markers/${marker.id}/name`,{method:'PATCH',body:JSON.stringify({name})});emit('map:marker-renamed',updated);showStatus('Название маркера сохранено',2000);}catch(error){save.disabled=false;showStatus(error.message,5000);}};
  box.append(renameForm);
  if(isAdmin()){
    const remove=document.createElement('button');remove.type='button';remove.className='marker-popover-delete';remove.textContent='Удалить маркер';remove.onclick=async()=>{if(!window.confirm(`Удалить маркер «${marker.name}»?`))return;remove.disabled=true;try{await api(`admin/markers/${marker.id}`,{method:'DELETE'});emit('map:marker-deleted',Number(marker.id));closeMarkerPopover();showStatus('Маркер удалён',2000);}catch(error){remove.disabled=false;showStatus(error.message,5000);}};
    box.append(remove);
  }
  box.dataset.markerId=String(marker.id);document.body.append(box);markerPopover=box;
  positionMarkerPopover({x:event.detail.screenX,y:event.detail.screenY,visible:true});
});
window.addEventListener('map:marker-renamed',event=>{
  const marker=event.detail;if(!marker)return;
  mapMarkers=mapMarkers.map(item=>Number(item.id)===Number(marker.id)?{...item,...marker}:item);
  if(current==='admin')updateMarkerAdminList($('marker-create-form')?.closest('.panel-group'));
  if(markerPopover?.dataset.markerId===String(marker.id)){
    const title=markerPopover.querySelector('header h2'),input=markerPopover.querySelector('.marker-rename-form input');
    if(title)title.textContent=`${MARKERS[marker.type]||marker.type}: ${marker.name}`;
    if(input)input.value=marker.name;
  }
});
