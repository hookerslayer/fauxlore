import {mountChat,unmountChat} from './chat.js';
const $=id=>document.getElementById(id);
export const LAYERS={states:'Государства',races:'Расы',religions:'Религии',resources:'Ресурсы',trade:'Торговые зоны',climate:'Климат',population:'Плотность населения',development:'Развитие'};
const MARKERS={capital:'Столица',city:'Город',fortress:'Крепость',port:'Порт',ruins:'Руины',interest:'Точка интереса'};
const INFO={roads:'Дороги',routes:'Торговые пути',provinces:'Названия провинций',states:'Названия государств',races:'Названия рас',religions:'Названия религий',resources:'Названия ресурсов',trade:'Названия торговых зон'};
const MENU=['Профиль','Чат','Стена','Статистика','Уведомления','Дипломатия','Власть и династия','Провинции','Города','Экономика','Производство','Торговля','Военное дело','Шпионаж','Правила и механики','Сообщество VK'];
const PANELS={auth:['Авторизация','user-round','left'],menu:['Меню','menu','left'],legend:['Легенда','list','left'],control:['Управление','sliders-horizontal','right'],markers:['Маркеры','map-pin','right'],info:['Информация','info','right'],tools:['Инструменты','ruler','right'],admin:['Администрирование','shield','right']};
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const emit=(name,detail)=>window.dispatchEvent(new CustomEvent(name,{detail}));
let current=null,user=null,categories=[],allProvinces=[],toolMode='',lastToolResult='',saveTimer,showStatus=()=>{},adminEditing=false,paintField='climate',paintValue='',paintActive=false,legendOpen=false;
let testProfileId=localStorage.getItem('fauxlore.test-profile')||'',menuChatHost=null;
const BULK_FIELDS=[['race','Раса'],['religion','Религия'],['state','Государство'],['province_type','Тип провинции'],['courts','Дворы'],['resource','Ресурс'],['trade','Торговая зона'],['development','Развитие'],['control','Контроль'],['climate','Климат'],['capital','Маркер столицы'],['city','Маркер города']];
let bulkRules=[{condition_field:'climate',condition_value:'Холодный',target_field:'courts',target_value:800},{condition_field:'climate',condition_value:'Умеренный',target_field:'courts',target_value:1000},{condition_field:'climate',condition_value:'Тропический',target_field:'courts',target_value:1200}],bulkPreview=null,bulkBusy=false;
const panelPages={};let layoutFrame=0;
export let settings={layer:'states',showIds:false,markers:{names:true,...Object.fromEntries(Object.keys(MARKERS).map(k=>[k,true]))},information:Object.fromEntries(Object.keys(INFO).map(k=>[k,false]))};
try{const saved=JSON.parse(localStorage.getItem('fauxlore.map-settings')||'{}');settings={...settings,...saved,markers:{...settings.markers,...saved.markers},information:{...settings.information,...saved.information}};}catch{}
if(!LAYERS[settings.layer])settings.layer='states';
export const isAdminEditing=()=>adminEditing&&user?.role==='admin';
export const isAdminPainting=()=>paintActive&&isAdminEditing();
export const canRenameProvince=stateId=>!!user&&stateId!=null&&user.state_ids?.includes(Number(stateId));
export const getCategories=()=>categories;
export async function api(path,options={}) {
  const headers={'Content-Type':'application/json',...options.headers};
  if(testProfileId&&(path==='profile'||path.startsWith('profile/avatar')||path==='chat/messages'||path.startsWith('chat/messages/')))headers['X-Fauxlore-Test-Profile']=testProfileId;
  const response=await fetch('/api/'+path,{...options,headers,credentials:'same-origin'});
  let body;try{body=await response.json();}catch{throw new Error('Сервер API недоступен. Запустите PostgreSQL и приложение через tools/start-local.ps1, затем откройте порт 8002.');}
  if(!response.ok){const detail=body.detail;throw new Error(typeof detail==='string'?detail:detail?.message||'Проверьте заполнение полей');}
  return body;
}
function save(){
  try{localStorage.setItem('fauxlore.map-settings',JSON.stringify(settings));}catch{}
  emit('map:settings',settings); clearTimeout(saveTimer);
  if(user)saveTimer=setTimeout(()=>api('preferences',{method:'PUT',body:JSON.stringify(settings)}).catch(e=>showStatus(e.message,4000)),600);
}
function updateDockState(){document.querySelectorAll('.dock-button').forEach(b=>{const active=b.dataset.panel==='legend'?legendOpen:b.dataset.panel===current;b.classList.toggle('active',active);b.setAttribute('aria-expanded',String(active));});document.body.classList.toggle('legend-open',legendOpen);}
function closeDrawer(){current=null;$('drawer').hidden=true;updateDockState();queueLayout();}
function closeLegend(){legendOpen=false;$('legend-drawer').hidden=true;updateDockState();queueLayout();}
function closeChat(){unmountChat($('chat-popover-content'));$('chat-popover').hidden=true;$('chat-toggle').setAttribute('aria-expanded','false');}
function closeAllDrawers(){closeDrawer();closeLegend();}
function openModal(title,auth=false){closeAllDrawers();closeChat();stopMenuChat();$('modal-title').textContent=title;$('modal').classList.toggle('auth-dialog',auth);if(!$('modal').open)$('modal').showModal();}
const checks=(entries,values,group)=>Object.entries(entries).map(([key,label])=>`<label class="check-row"><span>${label}</span><input type="checkbox" data-group="${group}" data-key="${key}" ${values[key]?'checked':''}></label>`).join('');
const group=(title,content)=>`<section class="panel-group" data-page-title="${title}">${content}</section>`;
const searchForm=()=>`<form id="search-form" class="stack"><label for="province-id">Поиск провинции по ID</label><div class="search-row"><input id="province-id" type="number" min="1" max="16777215" step="1" placeholder="ID" required><button type="submit">Найти</button></div></form>`;
const bulkCategoryLayer={race:'races',religion:'religions',state:'states',resource:'resources',trade:'trade',climate:'climate'};
function bulkValueControl(field,value,side,index){
  const id=`bulk-${side}-${index}`;
  if(bulkCategoryLayer[field]&&!(field==='state'&&side==='target')){
    const entries=categories.filter(c=>c.layer===bulkCategoryLayer[field]);
    return `<select data-bulk-value="${side}" data-index="${index}"><option value="" ${value==null?'selected':''}>Не задано</option>${entries.map(c=>`<option value="${escape(c.name)}" ${value===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
  }
  if(field==='province_type')return `<select data-bulk-value="${side}" data-index="${index}">${['Столица','Город','Регион','Колония','Нейтральная'].map(v=>`<option value="${v}" ${value===v?'selected':''}>${v}</option>`).join('')}</select>`;
  if(['capital','city'].includes(field))return `<select data-bulk-value="${side}" data-index="${index}"><option value="true" ${value===true?'selected':''}>Да</option><option value="false" ${value===false?'selected':''}>Нет</option></select>`;
  if(['courts','development'].includes(field))return `<input data-bulk-value="${side}" data-index="${index}" type="number" min="0" step="1" value="${escape(value??'')}" placeholder="Целое число">`;
  return `<input data-bulk-value="${side}" data-index="${index}" value="${escape(value??'')}" maxlength="120" placeholder="${field==='control'?'Название государства':'Значение'}">`;
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
  if(sections.length>1){
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
  if(current==='markers')host.innerHTML=group('Названия',checks({names:'Названия маркеров'},settings.markers,'markers'))+group('Типы',`<div class="check-grid">${checks(MARKERS,settings.markers,'markers')}</div><p class="hint">Маркеры столицы и города назначаются администратором в карточке провинции. Остальные типы будут добавлены позже.</p>`);
  if(current==='info')host.innerHTML=group('Поиск',searchForm())+group('Карта',`<div class="check-grid">${checks({ids:'ID провинций'},{ids:settings.showIds},'ids')}${checks({roads:INFO.roads,routes:INFO.routes},settings.information,'information')}</div>`)+group('Подписи',`<div class="check-grid">${checks(Object.fromEntries(Object.entries(INFO).filter(([k])=>!['roads','routes'].includes(k))),settings.information,'information')}</div>`);
  if(current==='tools')host.innerHTML=group('Инструмент',`<div class="tool-grid"><button data-tool="distance" aria-pressed="${toolMode==='distance'}">Расстояние</button><button data-tool="area" aria-pressed="${toolMode==='area'}">Площадь</button><button data-tool="coordinates" aria-pressed="${toolMode==='coordinates'}">Координаты</button><button id="copy-coordinates">Копировать точку</button></div>`)+group('Измерение',`<p class="hint">Две точки — расстояние. Три и более — площадь.</p><div id="tool-result" class="tool-result">${escape(lastToolResult||'Выберите инструмент')}</div><div class="tool-actions"><button id="finish-area">Завершить</button><button id="undo-point">Отменить точку</button><button id="clear-tool">Очистить</button></div>`)+group('Переход',`<form id="coordinate-form" class="stack"><label>Перейти к координатам</label><div class="coordinate-row"><input name="x" type="number" min="0" max="9999" step="any" placeholder="X" aria-label="Координата X" required><input name="y" type="number" min="0" max="9999" step="any" placeholder="Y" aria-label="Координата Y" required></div><button type="submit">Перейти</button></form>`);
  if(current==='admin'){
    const fields=[['name','Название'],['race','Раса'],['religion','Религия'],['state','Государство'],['province_type','Тип провинции'],['courts','Дворы'],['resource','Ресурс'],['trade','Торговая зона'],['development','Развитие'],['control','Контроль'],['climate','Климат'],['capital','Маркер столицы'],['city','Маркер города']];
    const field=fields.some(([key])=>key===paintField)?paintField:'climate';
    let valueControl='';
    if(['race','religion','resource','climate'].includes(field)){
      const layer={race:'races',religion:'religions',resource:'resources',trade:'trade',climate:'climate'}[field];
      valueControl=`<select id="admin-paint-value"><option value="">— очистить значение —</option>${categories.filter(c=>c.layer===layer).map(c=>`<option value="${escape(c.name)}" ${paintValue===c.name?'selected':''}>${escape(c.name)}</option>`).join('')}</select>`;
    }else if(field==='province_type')valueControl=`<select id="admin-paint-value">${['Столица','Город','Регион','Колония','Нейтральная'].map(v=>`<option ${paintValue===v?'selected':''}>${v}</option>`).join('')}</select>`;
    else if(['capital','city'].includes(field))valueControl=`<select id="admin-paint-value"><option value="true" ${paintValue==='true'?'selected':''}>Включить</option><option value="false" ${paintValue==='false'?'selected':''}>Выключить</option></select>`;
    else if(['courts','development'].includes(field))valueControl=`<input id="admin-paint-value" type="number" min="0" step="1" value="${escape(paintValue)}" placeholder="Целое число">`;
    else valueControl=`<input id="admin-paint-value" value="${escape(paintValue)}" maxlength="120" placeholder="${field==='state'?'Название государства':''}">`;
    host.innerHTML=`<section class="panel-group" data-page-title="Ручное редактирование"><span class="badge">ADMIN</span><h3>Провинции</h3><button id="toggle-admin-edit" aria-pressed="${adminEditing}">${adminEditing?'Завершить редактирование':'Режим редактирования'}</button><p class="hint">${adminEditing?'Выберите параметр и значение, затем включите нанесение и нажимайте на сухопутные провинции.':'В режиме редактирования доступны карточка провинции и массовое нанесение значений.'}</p>${adminEditing?`<label class="field"><span>Параметр</span><select id="admin-paint-field">${fields.map(([key,label])=>`<option value="${key}" ${field===key?'selected':''}>${label}</option>`).join('')}</select></label><label class="field"><span>Значение</span>${valueControl}</label><button id="toggle-admin-paint" aria-pressed="${paintActive}">${paintActive?'Завершить нанесение':'Наносить по кликам'}</button><p class="hint">${paintActive?'Нажимайте на провинции суши. Морские провинции не изменяются.':''}</p>`:''}</section>${group('Тестовые профили',`<p class="hint">Переключение влияет на сообщения, реакции и профиль в чате. Сессия администратора и его права сохраняются.</p><label class="field"><span>Активный профиль</span><select id="admin-test-profile"><option value="">Администратор</option></select></label>`)}${group('Массовое редактирование',`<p class="hint">Задайте одно или несколько правил «условие → значение». Сначала проверьте количество провинций, затем примените изменения.</p>${bulkRulesMarkup()}`)}`;
  }
  host.querySelectorAll('[data-layer]').forEach(b=>b.onclick=()=>{settings.layer=b.dataset.layer;save();renderDrawer();renderLegend();});
  if($('toggle-admin-edit'))$('toggle-admin-edit').onclick=()=>{adminEditing=!adminEditing;if(!adminEditing){paintActive=false;emit('map:admin-paint',null);}emit('admin:editing',{enabled:adminEditing});renderDrawer();};
  if($('admin-paint-field'))$('admin-paint-field').onchange=e=>{if(paintActive){paintActive=false;emit('map:admin-paint',null);}paintField=e.target.value;paintValue=({province_type:'Нейтральная',capital:'true',city:'true'}[paintField]||'');renderDrawer();};
  if($('admin-paint-value'))$('admin-paint-value').onchange=e=>{if(paintActive){paintActive=false;emit('map:admin-paint',null);const button=$('toggle-admin-paint');button.textContent='Наносить по кликам';button.setAttribute('aria-pressed','false');}paintValue=e.target.value;};
  if($('toggle-admin-paint'))$('toggle-admin-paint').onclick=()=>{const input=$('admin-paint-value');paintValue=input.value;if(['name','state','control'].includes(paintField)&&!paintValue.trim()){showStatus('Введите значение параметра',3000);return;}paintActive=!paintActive;emit('map:admin-paint',paintActive?{field:paintField,value:['courts','development'].includes(paintField)?Number(paintValue):['capital','city'].includes(paintField)?paintValue==='true':paintValue}:null);renderDrawer();};
  if($('admin-test-profile')){
    const select=$('admin-test-profile');select.value=testProfileId;
    api('admin/test-profiles').then(profiles=>{if(!select.isConnected)return;select.innerHTML='<option value="">Администратор</option>'+profiles.map(p=>`<option value="${p.id}">${escape(p.nickname)}</option>`).join('');select.value=testProfileId;}).catch(error=>showStatus(error.message,4000));
    select.onchange=()=>{testProfileId=select.value;try{if(testProfileId)localStorage.setItem('fauxlore.test-profile',testProfileId);else localStorage.removeItem('fauxlore.test-profile');}catch{}showStatus(testProfileId?'В чате активен тестовый профиль':'Возврат к профилю администратора',3000);if(!$('chat-popover').hidden)mountChatPanel($('chat-popover-content'));if(menuChatHost)mountChatPanel(menuChatHost);};
  }
  host.querySelectorAll('[data-bulk-field]').forEach(select=>select.onchange=()=>{const index=Number(select.dataset.index),side=select.dataset.bulkField,field=select.value;bulkRules[index][`${side}_field`]=field;bulkRules[index][`${side}_value`]=field==='province_type'?'Нейтральная':['capital','city'].includes(field)?true:['courts','development'].includes(field)?0:null;bulkPreview=null;renderDrawer();});
  host.querySelectorAll('[data-bulk-value]').forEach(input=>input.onchange=()=>{const index=Number(input.dataset.index),side=input.dataset.bulkValue,field=bulkRules[index][`${side}_field`];let value=input.value;if(['courts','development'].includes(field))value=Number(value);else if(['capital','city'].includes(field))value=value==='true';else if(value==='')value=null;bulkRules[index][`${side}_value`]=value;bulkPreview=null;renderDrawer();});
  host.querySelectorAll('[data-bulk-remove]').forEach(button=>button.onclick=()=>{if(bulkRules.length===1){showStatus('Добавьте другое правило перед удалением этого',3000);return;}bulkRules.splice(Number(button.dataset.bulkRemove),1);bulkPreview=null;renderDrawer();});
  if($('bulk-add'))$('bulk-add').onclick=()=>{bulkRules.push({condition_field:'climate',condition_value:null,target_field:'courts',target_value:0});bulkPreview=null;renderDrawer();};
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
    const values=allProvinces.map(p=>settings.layer==='population'?(p.population==null?null:p.population/p.area):p.development).filter(v=>v!=null);
    html+=values.length?`<p>От ${Math.min(...values).toLocaleString('ru-RU')} до ${Math.max(...values).toLocaleString('ru-RU')}${settings.layer==='population'?' чел./km²':''}</p><div class="gradient-key"></div>`:'<p class="hint">Показатели пока не заполнены.</p>';
  }else html+='<p class="hint">Для выбранного слоя данные пока не назначены.</p>';
  host.innerHTML=group('Слой',html)+group('Территории','<div class="legend-row"><i class="legend-swatch" style="background:#ffe7d6"></i><span>Нейтральные территории</span></div><div class="legend-row"><i class="legend-swatch" style="background:#486370"></i><span>Море</span></div><div class="legend-row"><i class="legend-swatch" style="background:#1f87ad"></i><span>Озеро</span></div>');
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
  user=next;if(user?.role!=='admin'){testProfileId='';try{localStorage.removeItem('fauxlore.test-profile');}catch{}adminEditing=false;paintActive=false;emit('map:admin-paint',null);}$('panel-admin').hidden=user?.role!=='admin';$('panel-auth').title=user?`Авторизация · ${user.nickname}`:'Авторизация';
  if(!user&&current==='admin')closeDrawer();
  if(user){try{const stored=await api('preferences');settings={...settings,...stored,markers:{...settings.markers,...stored.markers},information:{...settings.information,...stored.information}};if(!LAYERS[settings.layer])settings.layer='states';save();}catch(e){showStatus(e.message,4000);}}
}
function renderAuth(mode='login',token=''){
  openModal('Авторизация',true);const host=$('modal-content');
  if(user&&mode!=='reset'){
    host.innerHTML=`<div class="stack"><h3>${escape(user.nickname)}</h3><p>${escape(user.email)}</p><p class="hint">Роль: ${escape(user.role)}</p><button id="logout">Выйти</button></div>`;
    $('logout').onclick=async()=>{try{await api('auth/logout',{method:'POST',body:'{}'});await acceptUser(null);renderAuth();}catch(e){showStatus(e.message,4000);}};return;
  }
  host.innerHTML=`<div class="auth-tabs">${[['login','Вход'],['register','Регистрация'],['request','Сброс пароля']].map(([key,label])=>`<button data-auth="${key}" class="${mode===key?'active':''}">${label}</button>`).join('')}</div><form id="auth-form" class="stack">${mode==='register'?'<label class="field"><span>Имя</span><input name="nickname" minlength="2" maxlength="40" autocomplete="nickname" required></label>':''}${mode!=='reset'?'<label class="field"><span>Электронная почта</span><input name="email" type="email" maxlength="254" autocomplete="email" required></label>':''}${mode!=='request'?`<label class="field"><span>${mode==='reset'?'Новый пароль':'Пароль'}</span><input name="password" type="password" minlength="${mode==='login'?1:10}" maxlength="128" autocomplete="${mode==='login'?'current-password':'new-password'}" required></label>`:''}<button class="primary" type="submit">${{login:'Войти',register:'Создать аккаунт',request:'Отправить инструкцию',reset:'Сохранить пароль'}[mode]}</button><p id="auth-message" class="form-message hint" role="status">${mode==='register'?'Не менее 10 символов в пароле.':mode==='request'?'В локальном режиме письмо появится в папке .local/mail на сервере.':''}</p></form>`;
  host.querySelectorAll('[data-auth]').forEach(b=>b.onclick=()=>renderAuth(b.dataset.auth));
  $('auth-form').onsubmit=async e=>{
    e.preventDefault();const button=e.target.querySelector('[type=submit]');button.disabled=true;
    const body=Object.fromEntries(new FormData(e.target));if(mode==='reset')body.token=token;
    try{
      const result=await api(`auth/${{request:'reset-request',reset:'reset'}[mode]||mode}`,{method:'POST',body:JSON.stringify(body)});
      if(result.user){await acceptUser(result.user);$('modal').close();showStatus(`Вы вошли как ${result.user.nickname}`,3000);}
      else{$('auth-message').textContent=result.message;if(mode==='reset'){history.replaceState(null,'',location.pathname);setTimeout(()=>renderAuth(),1200);}}
    }catch(error){$('auth-message').textContent=error.message;}finally{button.disabled=false;}
  };
}
function mountChatPanel(host){mountChat(host,{api,user:()=>user,notify:showStatus,onLogin:()=>renderAuth()});}
async function renderProfile(host){
  if(!user){host.innerHTML='<h3>Профиль</h3><p class="hint">Войдите или зарегистрируйтесь, чтобы управлять профилем.</p><button id="profile-login">Войти</button>';host.querySelector('#profile-login').onclick=()=>renderAuth();return;}
  host.innerHTML='<p class="hint">Загружаю профиль…</p>';
  try{
    const profile=await api('profile');if(!host.isConnected)return;
    const avatar=profile.avatar_url?`<img class="profile-avatar" src="${escape(profile.avatar_url)}?v=${Date.now()}" alt="Аватар">`:`<span class="profile-avatar profile-avatar-fallback">${escape(profile.nickname.slice(0,1).toUpperCase())}</span>`;
    host.innerHTML=`<div class="profile-card">${avatar}<div><h3>${escape(profile.nickname)}${profile.is_test_profile?' · тестовый профиль':''}</h3><p class="hint">${escape(profile.email||'Тестовый аккаунт')} · ${profile.role==='admin'?'Администратор':'Игрок'}</p><p>Репутация: <strong>${profile.reputation}</strong></p></div></div><div class="profile-avatar-actions"><label class="chat-attach">${profile.avatar_url?'Сменить аватар':'Загрузить аватар'}<input id="profile-avatar-file" type="file" accept="image/png,image/jpeg,image/gif,image/webp" hidden></label>${profile.avatar_url?'<button id="profile-avatar-delete">Удалить аватар</button>':''}<span class="hint">PNG, JPEG, GIF или WebP · до 2 МБ</span></div>`;
    const avatarImage=host.querySelector('.profile-avatar');if(avatarImage)avatarImage.onerror=()=>{const fallback=document.createElement('span');fallback.className='profile-avatar profile-avatar-fallback';fallback.textContent=profile.nickname.slice(0,1).toUpperCase();fallback.setAttribute('aria-label','Аватар недоступен');avatarImage.replaceWith(fallback);};
    host.querySelector('#profile-avatar-file').onchange=async event=>{const file=event.target.files?.[0];if(!file)return;if(file.size>2*1024*1024){showStatus('Аватар должен быть не больше 2 МБ',4000);return;}try{const image_data=await readImageData(file);await api('profile/avatar',{method:'POST',body:JSON.stringify({image_data})});showStatus('Аватар обновлён',2500);renderProfile(host);}catch(error){showStatus(error.message,5000);}};
    host.querySelector('#profile-avatar-delete')?.addEventListener('click',async()=>{try{await api('profile/avatar',{method:'POST',body:JSON.stringify({image_data:null})});showStatus('Аватар удалён',2500);renderProfile(host);}catch(error){showStatus(error.message,5000);}});
  }catch(error){host.innerHTML=`<p class="chat-error">${escape(error.message)}</p>`;}
}
function readImageData(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error('Не удалось прочитать изображение'));reader.readAsDataURL(file);});}
function stopMenuChat(){if(menuChatHost)unmountChat(menuChatHost);menuChatHost=null;}
function renderMenu(section){
  stopMenuChat();
  openModal('Меню');const host=$('modal-content');host.innerHTML=`<div class="menu-layout"><nav class="menu-tabs" aria-label="Разделы сайта">${MENU.map(name=>`<button data-section="${name}" class="${name===section?'active':''}">${name}</button>`).join('')}</nav><section id="menu-section" class="placeholder"></section></div>`;
  host.querySelectorAll('[data-section]').forEach(b=>b.onclick=()=>renderMenu(b.dataset.section));
  const content=$('menu-section');
  if(section==='Профиль')renderProfile(content);
  else if(section==='Чат'){content.classList.add('chat-menu');content.innerHTML='<div id="menu-chat-host" class="chat-body"></div>';menuChatHost=content.querySelector('#menu-chat-host');mountChatPanel(menuChatHost);}
  else if(section==='Провинции'){
    content.innerHTML='<h3>Провинции</h3><p class="hint">Найдите провинцию по ID в панели «Информация» или выберите её на карте.</p><button id="menu-provinces">Открыть информацию</button>';
    $('menu-provinces').onclick=()=>{$('modal').close();togglePanel('info');};
  }else content.innerHTML=`<span class="badge">ЗАПЛАНИРОВАНО</span><h3>${escape(section)}</h3><p class="hint">${section==='Сообщество VK'?'Ссылка на сообщество Fauxlore ещё не задана.':'Раздел оформлен как заготовка. Содержание и игровые правила требуют уточнения.'}</p>`;
  if($('profile-login'))$('profile-login').onclick=()=>renderAuth();
}
export function initUI(notify){
  showStatus=notify;
  for(const[key,[name,icon,side]]of Object.entries(PANELS)){
    const button=document.createElement('button');button.className='dock-button';button.id=`panel-${key}`;button.dataset.panel=key;button.title=name;button.setAttribute('aria-label',name);button.setAttribute('aria-expanded','false');button.innerHTML=`<img src="assets/icons/${icon}.svg" alt="">`;
    if(key==='admin')button.hidden=true;button.onclick=()=>togglePanel(key);$(`${side}-dock`).append(button);
  }
  $('close-drawer').onclick=closeDrawer;$('close-legend').onclick=closeLegend;$('close-modal').onclick=()=>$('modal').close();$('chat-close').onclick=closeChat;
  $('chat-toggle').onclick=()=>{const panel=$('chat-popover');if(!panel.hidden){closeChat();return;}panel.hidden=false;$('chat-toggle').setAttribute('aria-expanded','true');mountChatPanel($('chat-popover-content'));};
  $('modal').addEventListener('close',stopMenuChat);
  $('modal').addEventListener('click',e=>{if(e.target===$('modal'))$('modal').close();});
  const observer=new ResizeObserver(queueLayout);observer.observe($('selection'));observer.observe($('map-scale'));
  window.addEventListener('resize',queueLayout);
  window.addEventListener('keydown',e=>{if(e.key==='Escape'){closeAllDrawers();emit('map:tool','');toolMode='';}});
  window.addEventListener('tools:result',e=>{lastToolResult=e.detail;if($('tool-result'))$('tool-result').textContent=e.detail;queueLayout();});
  const reset=new URLSearchParams(location.hash.slice(1)).get('reset');if(reset){history.replaceState(null,'',location.pathname);renderAuth('reset',reset);}
}
export async function hydrateUI(data){categories=data.categories;allProvinces=data.provinces;try{await acceptUser((await api('auth/me')).user);}catch(e){showStatus(e.message,4000);}emit('map:settings',settings);}
window.addEventListener('map:refreshed',e=>{categories=e.detail.categories;allProvinces=e.detail.provinces;if(current==='admin')renderDrawer();if(legendOpen)renderLegend();});
