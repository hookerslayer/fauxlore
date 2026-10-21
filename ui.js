import {supabaseApi,supabaseLogin,loadSupabaseInitialMap} from './supabase-api.js';
import {PRINCIPLES,governmentName,principleConflict} from './state-principles.js';
import {calculateProvinceEconomy,calculateProvinceValue,calculateStateProduction,buildTurnEconomyReport,RACE_TAX_RATES,RELIGION_TAX_RATES} from './economy.js?v=20261021155200';
const $=id=>document.getElementById(id);
export const LAYERS={states:'Государства',races:'Расы',religions:'Религии',resources:'Ресурсы',trade:'Торговые зоны',climate:'Климат',population:'Плотность населения',development:'Развитие'};
const MARKERS={capital:'Столица',city:'Город',fortress:'Крепость',port:'Порт'};
const INFO={roads:'Дороги',routes:'Торговые пути',provinces:'Названия провинций',states:'Названия государств',races:'Названия рас',religions:'Названия религий',resources:'Названия ресурсов',trade:'Названия торговых зон'};
const MENU=['Профиль','Стена','Статистика','Уведомления','Дипломатия','Власть и династия','Провинции','Города','Экономика','Производство','Торговля','Военное дело','Шпионаж','Правила и механики','Сообщество VK'];
const ADMIN_MENU_HIDDEN=new Set(['Статистика','Дипломатия','Власть и династия','Провинции','Города','Экономика','Производство','Торговля','Военное дело','Шпионаж']);
const STATE_SECTIONS=['Статистика','Власть и династия','Провинции','Производство'];
const PANELS={auth:['Авторизация','user-round','left'],menu:['Меню','menu','left'],legend:['Легенда','list','left'],control:['Управление','sliders-horizontal','right'],markers:['Маркеры','map-pin','right'],info:['Информация','info','right'],tools:['Инструменты','ruler','right'],admin:['Администрирование','shield','right']};
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const emit=(name,detail)=>window.dispatchEvent(new CustomEvent(name,{detail}));
let current=null,user=null,categories=[],allProvinces=[],provinceAdjacency={},mapMarkers=[],selectedProvince=null,pendingMarkerDraft=null,toolMode='',lastToolResult='',saveTimer,showStatus=()=>{},adminEditing=false,paintField='climate',paintValue='',paintActive=false,legendOpen=false,stateRows=[],applicationDraft=null,applicationPickMode=null;
const BELONGING_VALUES=['Корона','Знать','Духовенство','Горожане','Крестьяне','Отсутствует'];
const TRADE_STATUS_VALUES=['Отсутствует','Устье реки','Природный порт','Центр торговли I','Центр торговли II','Центр торговли III'];
const BULK_FIELDS=[['race','Раса'],['religion','Религия'],['state','Государство'],['occupation','Оккупация'],['population','Население'],['belonging','Принадлежность'],['trade_status','Торговый статус'],['resource','Ресурс'],['trade','Торговая зона'],['development','Развитие'],['control','Контроль, %'],['climate','Климат'],['terrain_type','Тип местности'],['capital','Маркер столицы'],['city','Маркер города']];
let bulkRules=[{condition_field:'climate',condition_value:'Холодный',target_field:'population',target_value:2000},{condition_field:'climate',condition_value:'Умеренный',target_field:'population',target_value:4000},{condition_field:'climate',condition_value:'Тропический',target_field:'population',target_value:5000}],bulkPreview=null,bulkBusy=false;
const panelPages={};let layoutFrame=0;
let adminTool='manual',colorLayer='resources',colorCategoryId=null;
const ADMIN_TOOLS={manual:'Ручное редактирование',bulk:'Массовое редактирование',markers:'Создать маркер',colors:'Цвета параметров',roads:'Прокладывание дорог'};
const ROAD_TYPES={trail:'Тропа',highway:'Тракт',imperial:'Имперская'};
let roadsList=[],roadInfo={active:false,busy:false,anchors:[],segments:[]},roadType='trail';
function roadMarkup(){
  const count=roadInfo.anchors.length;
  return group('Прокладывание дорог',`<label class="field"><span>Тип дороги</span><select id="road-type" ${roadInfo.active?'disabled':''}>${Object.entries(ROAD_TYPES).map(([key,name])=>`<option value="${key}" ${key===roadType?'selected':''}>${name}</option>`).join('')}</select></label><p class="hint">Клик по провинции — её центр. Клик по маркеру — сам маркер. Добавляйте соседние провинции последовательно. Пунктир — тропа, штрихи — тракт, сплошная линия — имперская дорога.</p>${roadInfo.active?`<div class="tool-result">Точек: ${count}${roadInfo.busy?' · Расчёт / сохранение…':''}</div><button id="road-undo" ${roadInfo.busy||!count?'disabled':''}>Убрать последнюю точку</button><button id="road-save" ${roadInfo.busy||count<2?'disabled':''}>Сохранить дорогу</button><button id="road-cancel" ${roadInfo.saving?'disabled':''}>Отмена</button>`:'<button id="road-start">Начать прокладывание</button>'}<p class="hint">Сохранённых дорог: ${roadsList.length}. Видимость переключается в панели «Информация → Дороги».</p>${roadsList.map(road=>`<div class="marker-admin-row"><span>№ ${road.id} · ${ROAD_TYPES[road.type]||escape(road.type)} · ${road.anchors.length} точек</span><button data-delete-road="${road.id}" ${roadInfo.busy?'disabled':''} aria-label="Удалить дорогу ${road.id}">×</button></div>`).join('')}`);
}
function categoryColorsMarkup(){
  const entries=categories.filter(c=>c.layer===colorLayer);
  const selected=entries.find(c=>c.id===Number(colorCategoryId))||entries[0];
  colorCategoryId=selected?.id??null;
  return group('Цвета параметров',`<form id="category-color-form" class="stack"><label class="field"><span>Параметр</span><select id="category-color-layer">${Object.entries(LAYERS).filter(([key])=>!['population','development'].includes(key)).map(([key,label])=>`<option value="${key}" ${key===colorLayer?'selected':''}>${label}</option>`).join('')}</select></label><label class="field"><span>Значение</span><select id="category-color-value" ${selected?'':'disabled'}>${entries.map(c=>`<option value="${c.id}" ${c.id===colorCategoryId?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label>${selected?`<label class="field"><span>Цвет</span><input id="category-color" type="color" value="${/^#[0-9a-f]{6}$/i.test(selected.color)?selected.color:'#888888'}"><output id="category-color-code">${escape(selected.color)}</output></label><button type="submit" class="primary">Сохранить цвет</button><p class="hint">Цвет изменится во всех провинциях с этим значением.</p>`:'<p class="hint">Значения этого параметра ещё не созданы.</p>'}</form>`);
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
    const content=['colors','roads'].includes(adminTool)?null:[...host.children].find(section=>section.dataset.pageTitle===title);
    if(adminTool==='colors')host.innerHTML=categoryColorsMarkup();
    else if(adminTool==='roads')host.innerHTML=roadMarkup();
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
  user=next;$('advance-turn').hidden=user?.role!=='admin';if(user?.role!=='admin'){adminEditing=false;paintActive=false;emit('map:admin-paint',null);emit('roads:cancel');}$('panel-admin').hidden=user?.role!=='admin';$('panel-auth').title=user?`Авторизация · ${user.nickname}`:'Авторизация';
  if(!user&&current==='admin')closeDrawer();
  if(user){try{const stored=await api('preferences');settings={...settings,...stored,markers:{...settings.markers,...stored.markers},information:{...settings.information,...stored.information}};if(!LAYERS[settings.layer])settings.layer='states';save();}catch(e){showStatus(e.message,4000);}}
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
  host.innerHTML=`<form id="player-application-form" class="application-form stack"><h3>Анкета государства</h3><label class="field"><span>Название государства</span><input name="state_name" maxlength="100" required value="${escape(d.state_name||'')}"></label><label class="field"><span>Цвет на карте</span><input name="state_color" type="color" value="${escape(d.state_color||'#657e91')}"></label>${principles}<label class="field"><span>Имя правителя</span><input name="ruler_name" maxlength="100" required value="${escape(d.ruler_name||'')}"></label><label class="field"><span>Пол правителя</span><select name="ruler_gender"><option>Мужской</option><option ${d.ruler_gender==='Женский'?'selected':''}>Женский</option></select></label><label class="field"><span>Титул правителя</span><input name="ruler_title" maxlength="100" required value="${escape(d.ruler_title||'')}"></label><label class="field"><span>Возраст правителя (от 30)</span><input name="ruler_age" type="number" min="30" required value="${escape(d.ruler_age||30)}"></label><label class="field"><span>Официальная раса</span><select name="race_id">${categories.filter(c=>c.layer==='races').map(c=>`<option value="${c.id}" ${Number(d.race_id)===c.id?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>Официальная религия</span><select name="religion_id">${categories.filter(c=>c.layer==='religions').map(c=>`<option value="${c.id}" ${Number(d.religion_id)===c.id?'selected':''}>${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>История и описание (<output id="history-count">${(d.history||'').length}</output>/1500–4000)</span><textarea name="history" minlength="1500" maxlength="4000" rows="8" required>${escape(d.history||'')}</textarea></label><section class="application-panel"><h3>Территория и столица</h3><p>${d.province_ids.length}/5 выбрано${provinceLabels?`: ${escape(provinceLabels)}`:''}</p><button id="pick-application-provinces" type="button">Выбрать провинции на карте</button><button id="pick-application-capital" type="button" ${d.province_ids.length!==5?'disabled':''}>${d.capital_province_id?'Изменить провинцию столицы':'Выбрать столицу на карте'}</button><p>Столица: ${escape(allProvinces.find(p=>p.id===Number(d.capital_province_id))?.name||'не выбрана')}</p><label class="field"><span>Название столицы</span><input name="capital_name" maxlength="120" required value="${escape(d.capital_name||'')}"></label></section><label class="field"><span>Флаг / символика (JPG, JPEG, PNG или WebP, до 2 МБ)</span><input id="application-emblem" type="file" accept="image/jpeg,image/png,image/webp" ${d.emblem_data?'':'required'}></label>${d.emblem_data?`<img class="application-emblem-preview" src="${d.emblem_data}" alt="Предпросмотр символики">`:''}<label class="check-row"><span>Я изучил Правила и Механики проекта</span><input name="rules_acknowledged" type="checkbox" required ${d.rules_acknowledged?'checked':''}></label><p id="application-form-message" class="form-message" role="status"></p><button class="primary" type="submit">Отправить анкету</button><button id="cancel-application" type="button">Отмена</button></form>`;
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
    const problem=principleConflict(d.principles)||(!applicationIsConnected(d.province_ids)?'Провинции должны соседствовать напрямую или через одну морскую провинцию.':'')||(applicationColorConflicts(d.state_color,d.province_ids)?'Выберите цвет, заметно отличающийся от цветов соседних государств.':'')||(!d.capital_province_id?'Выберите провинцию столицы.':'')||(!d.emblem_data?'Загрузите символику государства.':'')||(!data.rules_acknowledged?'Подтвердите ознакомление с Правилами и Механиками.':'');
    if(problem){host.querySelector('#application-form-message').textContent=problem;return;}
    const submit=form.querySelector('[type=submit]');submit.disabled=true;
    const payload={state_name:data.state_name,state_color:data.state_color,principles:d.principles,ruler_name:data.ruler_name,ruler_gender:data.ruler_gender,ruler_title:data.ruler_title,ruler_age:Number(data.ruler_age),race_id:Number(data.race_id),religion_id:Number(data.religion_id),history:data.history,province_ids:d.province_ids.map(Number),capital_province_id:Number(d.capital_province_id),capital_name:data.capital_name,emblem_data:d.emblem_data,rules_acknowledged:!!data.rules_acknowledged};
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
  try{const rows=await api('notifications');if(!host.isConnected)return;host.innerHTML=`<div class="notification-list stack"><h3>Уведомления</h3>${rows.length?rows.map(x=>`<article class="application-panel"><strong>${escape(x.title)}</strong><p>${escape(x.message)}</p><small>${new Date(x.created_at).toLocaleString('ru-RU')}</small>${x.read?'':`<button data-read-notification="${x.id}">Отметить прочитанным</button>`}</article>`).join(''):'<p class="hint">Уведомлений пока нет.</p>'}</div>`;host.querySelectorAll('[data-read-notification]').forEach(b=>b.onclick=async()=>{try{await api(`notifications/${b.dataset.readNotification}/read`,{method:'PATCH',body:'{}'});renderNotifications(host);}catch(e){showStatus(e.message,4000);}});}
  catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}
function readImageData(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error('Не удалось прочитать изображение'));reader.readAsDataURL(file);});}
const menuSections=()=>user?.role==='admin'
  ? [...MENU.filter(name=>!ADMIN_MENU_HIDDEN.has(name)).slice(0,2),'Государства',...MENU.filter(name=>!ADMIN_MENU_HIDDEN.has(name)).slice(2)]
  : MENU.filter(name=>name!=='Города');

function renderMenu(section='Профиль'){
  openModal('Меню');
  const sections=menuSections();if(!sections.includes(section))section='Профиль';
  const header=$('modal-title').parentElement;
  header.querySelector('.menu-mobile-picker')?.remove();
  const picker=document.createElement('select');picker.className='menu-mobile-picker';picker.setAttribute('aria-label','Раздел меню');
  picker.innerHTML=sections.map(name=>`<option value="${escape(name)}" ${name===section?'selected':''}>${escape(name)}</option>`).join('');
  picker.onchange=()=>renderMenu(picker.value);header.insertBefore(picker,$('close-modal'));
  const host=$('modal-content');
  host.innerHTML=`<div class="menu-layout"><nav class="menu-tabs" aria-label="Разделы сайта">${sections.map(name=>`<button type="button" data-section="${escape(name)}" class="${name===section?'active':''}">${escape(name)}</button>`).join('')}</nav><section id="menu-section" class="placeholder"></section></div>`;
  host.querySelectorAll('[data-section]').forEach(b=>b.onclick=()=>renderMenu(b.dataset.section));
  const content=$('menu-section');
  if(section==='Профиль')renderProfile(content);
  else if(section==='Государства'&&user?.role==='admin')renderStatesMenu(content);
  else if(section==='Уведомления'&&user)renderNotifications(content);
  else if(['Статистика','Власть и династия','Провинции','Производство'].includes(section))renderPlayerStateSection(content,section);
  else content.innerHTML=`<span class="badge">ЗАПЛАНИРОВАНО</span><h3>${escape(section)}</h3><p class="hint">${section==='Сообщество VK'?'Ссылка на сообщество Fauxlore ещё не задана.':'Раздел оформлен как заготовка. Содержание и игровые правила требуют уточнения.'}</p>`;
  if($('profile-login'))$('profile-login').onclick=()=>renderAuth();
}

function renderPlayerStateSection(host,tab){
  if(!user){host.innerHTML='<h3>Государство</h3><p class="hint">Войдите, чтобы открыть государственные данные.</p>';return;}
  host.innerHTML='<p class="hint">Загружаю государство…</p>';
  api('my/states').then(states=>{
    if(!host.isConnected)return;
    if(!states.length){host.innerHTML='<h3>Государство</h3><p class="hint">За вашим аккаунтом пока не закреплено государство. Администратор должен назначить его игроку.</p>';return;}
    const chosen=states.find(state=>user.state_ids?.includes(Number(state.id)))||states[0];
    const stateCategory=categories.find(category=>category.layer==='states'&&category.id===Number(chosen.id));
    const crime=Number(chosen.crime??stateCategory?.crime??.2);
    const provinces=(chosen.provinces||[]).map(p=>({...p,layers:{states:{id:Number(chosen.id),name:chosen.name,crime},races:p.race?{name:p.race}:null,religions:p.religion?{name:p.religion}:null,resources:p.resource?{name:p.resource}:null}}));
    renderStateDetails(host,{...chosen,crime},tab,provinces,false);
  }).catch(error=>{if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;});
}

function renderStateDetails(host,state,tab,provinces,isAdmin){
  const population=provinces.reduce((sum,p)=>sum+Number(p.population||0),0);
  const provinceEconomy=provinces.map(p=>calculateProvinceEconomy(p));
  const unresolvedTaxes=provinceEconomy.filter(item=>item.taxes===null).length;
  const productionRows=calculateStateProduction(provinces);
  const crime=Number(state.crime??provinces.find(p=>p.layers?.states?.crime!=null)?.layers.states.crime??.2);
  const groupStats=(layer,official)=>{
    const groups=new Map();
    for(const province of provinces){
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
    const members=provinces.filter(province=>province.belonging===name);
    const values=members.map(calculateProvinceValue);
    return {name,provinceCount:members.length,population:members.reduce((sum,province)=>sum+(Number(province.population)||0),0),
      weight:values.some(value=>value===null)?null:values.reduce((sum,value)=>sum+value,0)};
  });
  const estateStats=allEstateStats.filter(item=>item.provinceCount>0);
  const totalEstateWeight=allEstateStats.every(item=>item.weight!==null)?allEstateStats.reduce((sum,item)=>sum+item.weight,0):null;
  const pct=value=>`${(value*100).toLocaleString('ru-RU',{minimumFractionDigits:1,maximumFractionDigits:1})}%`;
  const groupTable=(title,rows,rates)=>`<h4>${title}</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Название</th><th>Статус</th><th>Население</th><th>Доля</th><th>Базовая ставка, G</th><th>Стабилизация</th></tr></thead><tbody>${rows.length?rows.map(row=>`<tr><td>${escape(row.name)}</td><td>${row.status}</td><td>${row.population.toLocaleString('ru-RU')}</td><td>${pct(row.share)}</td><td>${rates[row.name]===undefined?'—':rates[row.name].toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})}</td><td>—</td></tr>`).join(''):`<tr><td colspan="6" class="hint">Нет назначенных значений.</td></tr>`}</tbody></table></div>`;
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
    const totalDevelopment=provinces.some(province=>province.development!==null&&province.development!==undefined)
      ?provinces.reduce((sum,province)=>sum+(Number(province.development)||0),0):null;
    const urbanPopulation=provinces.reduce((sum,province)=>sum+Number(province.population||0)*({Столичная:.35,Городская:.2}[province.province_type]||0),0);
    const ruralPopulation=population-urbanPopulation;
    const estatesTable=estateStats.length
      ?`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Сословие</th><th>Статус</th><th>Население</th><th>Вес</th><th>Влияние</th><th>Стабилизация</th></tr></thead><tbody>${estateStats.map(item=>`<tr><td>${escape(item.name)}</td><td>${estateStatus(item.name)}</td><td>${item.population.toLocaleString('ru-RU')}</td><td>${item.weight===null?'—':item.weight.toLocaleString('ru-RU')}</td><td>${totalEstateWeight&&item.weight!==null?pct(item.weight/totalEstateWeight):'—'}</td><td>—</td></tr>`).join('')}</tbody></table></div>`
      :'<div class="table-scroll"><table class="state-data-table"><tbody><tr><td class="hint">В провинциях не назначены сословия.</td></tr></tbody></table></div>';
    const advisors=[['Административный','Казначей'],['Глашатай','Купец'],['Стратег','Штабист']];
    const advisorsTable=`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Советник</th><th>Имя советника</th><th>Уровень</th><th>Тип советника</th><th>Бонус</th><th>Содержание ОП/ход</th></tr></thead><tbody>${advisors.map(([type,specialty])=>`<tr><td>${type}</td><td>—</td><td>1</td><td>${specialty}</td><td>—</td><td>1</td></tr>`).join('')}</tbody></table></div>`;
    detail=`<div class="state-identity"><div class="state-emblem-frame"><div class="state-emblem-placeholder" data-emblem-placeholder>Символика<br>не загружена</div><img class="state-emblem-image" data-state-emblem alt="Символика государства" hidden>${isAdmin?`<button type="button" class="state-emblem-edit" data-emblem-toggle aria-label="Редактировать символику" title="Редактировать символику"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 16.5V20h3.5L18 9.5 14.5 6 4 16.5Z"/><path d="m12.5 8 3.5 3.5M14 4l2-2 6 6-2 2"/></svg></button><div class="state-emblem-menu" data-emblem-menu hidden><button type="button" data-emblem-change>Загрузить / сменить</button><button type="button" class="danger-button" data-emblem-delete hidden>Удалить символику</button></div><input type="file" data-emblem-file accept="image/jpeg,image/png,image/webp" hidden>`:''}</div><div class="state-identity-facts"><div><small>Официальная раса</small><strong>${escape(state.official_race||'—')}</strong></div><div><small>Официальная религия</small><strong>${escape(state.official_religion||'—')}</strong></div><div><small>Форма правления</small><strong>${escape(state.form_name||'Не задана')}</strong></div></div></div><div class="state-dashboard-top"><section class="state-dashboard-card"><h4>Состояние государства</h4><div class="state-condition-list"><div><small>Лимит развития</small><strong>—</strong></div><div><small>Совокупное развитие</small><strong>${totalDevelopment===null?'—':totalDevelopment.toLocaleString('ru-RU')}</strong></div><div><small>Стабильность государства</small><strong>—</strong></div><div><small>Коррупция</small><strong>${Math.round(Number(state.corruption??.2)*100)}%</strong></div><div><small>Преступность</small><strong>${Math.round(crime*100)}%</strong></div></div></section><section class="state-dashboard-card"><h4>Население</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Показатель</th><th>Численность</th></tr></thead><tbody><tr><td>Городское</td><td>${Math.round(urbanPopulation).toLocaleString('ru-RU')}</td></tr><tr><td>Сельское</td><td>${Math.round(ruralPopulation).toLocaleString('ru-RU')}</td></tr><tr><td>Общее</td><td>${population.toLocaleString('ru-RU')}</td></tr></tbody></table></div></section></div><h4>Советники правителя</h4>${advisorsTable}<h4>Сословия</h4>${estatesTable}${groupTable('Расы',groupStats('races',state.official_race),RACE_TAX_RATES)}${groupTable('Религии',groupStats('religions',state.official_religion),RELIGION_TAX_RATES)}<p class="hint">Вес сословия суммирует рассчитанную ценность его провинций; влияние — доля веса, рассчитанная с учётом всех пяти сословий. Компонент рекрутского лимита пока не включён. Стабилизация групп, лимит развития и стабильность государства пока требуют дополнительных игровых параметров. Доходы казны не распределяются. ${unresolvedTaxes?`Не рассчитано провинций по налогам: ${unresolvedTaxes}.`:''}</p>`;
  }
  else if(tab==='Власть и династия')detail=`<div class="government-card"><small>Форма правления</small><strong>${escape(state.form_name||'Не задана')}</strong></div><div class="state-facts">${Object.entries(principles).map(([key,value])=>`<p><span>${escape(principleLabels[key]||key)}</span><strong>${escape(value)}</strong></p>`).join('')||'<p class="hint">Принципы государства не заданы.</p>'}<p><span>Официальная раса</span><strong>${escape(state.official_race||'—')}</strong></p><p><span>Официальная религия</span><strong>${escape(state.official_religion||'—')}</strong></p><p><span>Коррупция</span><strong>${Math.round(Number(state.corruption??.2)*100)}%</strong></p><p><span>Преступность</span><strong>${Math.round(crime*100)}%</strong></p></div>`;
  else if(tab==='Провинции')detail=`<p class="hint">Провинций государства: ${Number(state.province_count??provinces.length).toLocaleString('ru-RU')}. Ценность пока не включает рекрутскую составляющую; прирост и лимит рекрутов не рассчитываются. Нажмите заголовок, чтобы отсортировать таблицу.</p><div class="table-scroll provinces-table-scroll"><table class="state-data-table provinces-data-table"><thead><tr>${['Название провинции','ID','Раса','Религия','Тип пров.','Торговый статус','Принадлежность','Ресурс','Население','Рост населения','Ценность','КМ, %','Налоги','Торг. влияние','Производство','Прирост рекр.','Лимит рекр.'].map((label,index)=>`<th><button type="button" class="province-sort-button" data-sort-column="${index}" aria-label="Сортировать по столбцу ${label}">${label}<span aria-hidden="true"> ↕</span></button></th>`).join('')}</tr></thead><tbody>${provinces.length?provinces.map(p=>{const economy=calculateProvinceEconomy(p),value=calculateProvinceValue(p);return `<tr><td>${escape(p.name||'—')}</td><td>${p.id}</td><td>${escape(p.layers?.races?.name||'—')}</td><td>${escape(p.layers?.religions?.name||'—')}</td><td>${escape(p.province_type||'—')}</td><td>${escape(p.trade_status||'Отсутствует')}</td><td>${escape(p.belonging||'Отсутствует')}</td><td>${escape(p.layers?.resources?.name||'—')}</td><td>${Number(p.population||0).toLocaleString('ru-RU')}</td><td>${economy.populationGrowth===null?'—':economy.populationGrowth.toLocaleString('ru-RU')}</td><td>${value===null?'—':value.toLocaleString('ru-RU')}</td><td>${Number(p.control??100).toLocaleString('ru-RU')}%</td><td>${economy.taxes===null?'—':economy.taxes.toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})}</td><td>${economy.tradeInfluence===null?'—':economy.tradeInfluence.toLocaleString('ru-RU',{minimumFractionDigits:2,maximumFractionDigits:2})}</td><td>${economy.production===null?'—':economy.production.toLocaleString('ru-RU')}</td><td>—</td><td>—</td></tr>`}).join(''):'<tr><td colspan="17" class="hint">У государства пока нет провинций.</td></tr>'}</tbody></table></div>`;
  else if(tab==='Производство'){
    const resourceGroups=[...new Set(productionRows.map(row=>row.category))];
    const rows=resourceGroups.map(category=>`<tr class="resource-category-row"><th colspan="6">${escape(category)}</th></tr>${productionRows.filter(row=>row.category===category).map(row=>`<tr><td>${escape(row.resource)}</td><td>${row.production===null?'—':row.production.toLocaleString('ru-RU')}</td><td>${row.consumption.toLocaleString('ru-RU')}</td><td class="${row.balance===null?'':row.balance>0?'balance-positive':row.balance<0?'balance-negative':''}">${row.balance===null?'—':row.balance.toLocaleString('ru-RU')}</td><td>—</td><td>—</td></tr>`).join('')}`).join('');
    const unresolved=productionRows.filter(row=>row.unresolved).length;
    detail=`<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Ресурс</th><th>Производство</th><th>Потребление</th><th>Баланс</th><th>Импорт</th><th>Экспорт</th></tr></thead><tbody>${rows}</tbody></table></div><p class="hint">Производство рассчитано по назначенному ресурсу, населению, типу провинции и контролю, затем уменьшено на преступность государства (${Math.round(crime*100)}%). Потребление = ROUNDUP(население / 10 × коэффициент). Эфемерная и Магическая пустоши в таблицу не включаются. ${unresolved?`Не рассчитано ресурсных строк: ${unresolved} из-за отсутствующих входных данных.`:''} Импорт/экспорт не рассчитываются; запасы не ведутся.</p>`;
  }
  host.innerHTML=`<div class="state-menu stack">${isAdmin?'<button id="state-back" type="button">← Все государства</button>':''}<div class="state-heading"><span class="state-color" style="background:${escape(state.color||'#777777')}"></span><h3>${escape(state.name)}</h3></div>${isAdmin?`<nav class="state-subtabs" aria-label="Разделы государства">${STATE_SECTIONS.map(name=>`<button type="button" data-state-tab="${escape(name)}" class="${name===tab?'active':''}">${escape(name)}</button>`).join('')}</nav>`:''}<section class="state-detail"><h3>${escape(tab)}</h3>${detail}</section>${isAdmin?'<button id="state-delete" class="danger-button" type="button">Удалить государство</button>':''}</div>`;
  if(tab==='Статистика')bindStateEmblem(host,state,isAdmin);
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
        const left=a.cells[column]?.textContent.trim()||'',right=b.cells[column]?.textContent.trim()||'';
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
  try{stateRows=await api('admin/states');if(!host.isConnected)return;renderStatesContent(host);}
  catch(error){if(host.isConnected)host.innerHTML=`<p class="form-message">${escape(error.message)}</p>`;}
}

function renderStatesContent(host,selectedId=null,tab='Статистика',create=false){
  if(!host.isConnected)return;
  const state=stateRows.find(row=>row.id===Number(selectedId));
  if(state){
    const local=allProvinces.filter(p=>p.kind==='land'&&Number(p.layers?.states?.id)===state.id);
    renderStateDetails(host,state,tab,local,true);
    return;
  }
  const stateList=stateRows.map(row=>`<button class="state-list-row" type="button" data-open-state="${row.id}"><span class="state-color" style="background:${escape(row.color)}"></span><span>${escape(row.name)}</span><small>${row.players?.length?'Игрок':row.is_npc?'NPC':'Без владельца'} · ${Number(row.province_count)} пров.</small></button>`).join('');
  const principleFields=Object.entries({authority:'Источник власти',structure:'Структура владения',economy:'Экономический уклад',military:'Военная доктрина',ephemeral:'Эфемерный вопрос'}).map(([key,label])=>`<label class="field"><span>${label}</span><select name="${key}" required>${PRINCIPLES[key].map(value=>`<option value="${escape(value)}">${escape(value)}</option>`).join('')}</select></label>`).join('');
  host.innerHTML=`<div class="state-menu stack"><div class="state-menu-heading"><h3>Государства</h3><button id="state-create-toggle" type="button">${create?'Список государств':'Создать NPC государство'}</button></div>${create?`<form id="state-create-form" class="stack"><label class="field"><span>Название</span><input name="name" maxlength="100" required></label><label class="field"><span>Цвет</span><input name="color" type="color" value="#ac805d" required></label>${principleFields}<label class="field"><span>Официальная раса</span><select name="race_id" required>${categories.filter(c=>c.layer==='races').map(c=>`<option value="${c.id}">${escape(c.name)}</option>`).join('')}</select></label><label class="field"><span>Официальная религия</span><select name="religion_id" required>${categories.filter(c=>c.layer==='religions').map(c=>`<option value="${c.id}">${escape(c.name)}</option>`).join('')}</select></label><p id="state-form-preview" class="hint"></p><p id="state-form-message" class="form-message" role="status"></p><button class="primary" type="submit">Создать государство</button></form>`:`<div class="state-list">${stateList||'<p class="hint">Государства ещё не созданы.</p>'}</div>`}</div>`;
  host.querySelector('#state-create-toggle').onclick=()=>renderStatesContent(host,null,'Статистика',!create);
  host.querySelectorAll('[data-open-state]').forEach(button=>button.onclick=()=>renderStatesContent(host,button.dataset.openState));
  const form=host.querySelector('#state-create-form');if(!form)return;
  form.setAttribute('role','dialog');form.setAttribute('aria-label','Создать NPC государство');
  const updatePreview=()=>{const selection=Object.fromEntries(new FormData(form));const problem=principleConflict(selection);const preview=host.querySelector('#state-form-preview');preview.textContent=problem||`Форма правления: ${governmentName(selection)}`;preview.classList.toggle('invalid',!!problem);form.querySelector('[type=submit]').disabled=!!problem;};
  form.querySelectorAll('select').forEach(select=>select.onchange=updatePreview);updatePreview();
  form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('[type=submit]');button.disabled=true;const payload=Object.fromEntries(new FormData(form));payload.race_id=Number(payload.race_id);payload.religion_id=Number(payload.religion_id);
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
    if(!confirm('Рассчитать экономические показатели за текущий ход и перейти на следующий год и ход?'))return;
    button.disabled=true;button.textContent='Расчёт…';
    try{renderCalendar(await api('admin/turn/advance',{method:'POST',body:JSON.stringify({expected_year:gameCalendar.year,expected_turn:gameCalendar.turn,report:buildTurnEconomyReport(allProvinces)})}));showStatus('Экономические итоги рассчитаны, год и ход увеличены на 1',4000);}
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
export function hydrateUI(data){categories=data.categories;allProvinces=data.provinces;provinceAdjacency=data.adjacency||{};roadsList=data.roads||[];emit('map:settings',settings);api('game/calendar').then(renderCalendar).catch(e=>showStatus(e.message,4000));api('auth/me').then(result=>acceptUser(result.user)).catch(e=>showStatus(e.message,4000));}
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
window.addEventListener('map:refreshed',e=>{categories=e.detail.categories;allProvinces=e.detail.provinces;provinceAdjacency=e.detail.adjacency||provinceAdjacency;mapMarkers=e.detail.markers||[];roadsList=e.detail.roads||[];if(current==='admin')renderDrawer();if(legendOpen)renderLegend();});
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
