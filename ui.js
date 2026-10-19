const $=id=>document.getElementById(id);
export const LAYERS={states:'Государства',races:'Расы',religions:'Религии',resources:'Ресурсы',trade:'Торговые зоны',climate:'Климат',population:'Плотность населения',development:'Развитие'};
const MARKERS={capital:'Столица',city:'Город',fortress:'Крепость',port:'Порт',ruins:'Руины',interest:'Точка интереса'};
const INFO={roads:'Дороги',routes:'Торговые пути',provinces:'Названия провинций',states:'Названия государств',races:'Названия рас',religions:'Названия религий',resources:'Названия ресурсов',trade:'Названия торговых зон'};
const MENU=['Профиль','Стена','Статистика','Уведомления','Дипломатия','Власть и династия','Провинции','Города','Экономика','Производство','Торговля','Военное дело','Шпионаж','Правила и механики','Сообщество VK'];
const PANELS={auth:['Авторизация','user-round','left'],menu:['Меню','menu','left'],legend:['Легенда','list','left'],control:['Управление','sliders-horizontal','right'],markers:['Маркеры','map-pin','right'],info:['Информация','info','right'],tools:['Инструменты','ruler','right'],admin:['Администрирование','shield','right']};
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const emit=(name,detail)=>window.dispatchEvent(new CustomEvent(name,{detail}));
let current=null,user=null,categories=[],allProvinces=[],toolMode='',lastToolResult='',saveTimer,showStatus=()=>{};
const panelPages={};let layoutFrame=0;
export let settings={layer:'states',showIds:false,markers:{names:true,...Object.fromEntries(Object.keys(MARKERS).map(k=>[k,true]))},information:Object.fromEntries(Object.keys(INFO).map(k=>[k,false]))};
try{const saved=JSON.parse(localStorage.getItem('fauxlore.map-settings')||'{}');settings={...settings,...saved,markers:{...settings.markers,...saved.markers},information:{...settings.information,...saved.information}};}catch{}
if(!LAYERS[settings.layer])settings.layer='states';
export async function api(path,options={}) {
  const response=await fetch('/api/'+path,{...options,headers:{'Content-Type':'application/json',...options.headers},credentials:'same-origin'});
  let body;try{body=await response.json();}catch{throw new Error('Сервер API недоступен. Запустите PostgreSQL и приложение через tools/start-local.ps1, затем откройте порт 8002.');}
  if(!response.ok){const detail=body.detail;throw new Error(typeof detail==='string'?detail:'Проверьте заполнение полей');}
  return body;
}
function save(){
  try{localStorage.setItem('fauxlore.map-settings',JSON.stringify(settings));}catch{}
  emit('map:settings',settings); clearTimeout(saveTimer);
  if(user)saveTimer=setTimeout(()=>api('preferences',{method:'PUT',body:JSON.stringify(settings)}).catch(e=>showStatus(e.message,4000)),600);
}
function closeDrawer(){current=null;$('drawer').hidden=true;document.querySelectorAll('.dock-button').forEach(b=>{b.classList.remove('active');b.setAttribute('aria-expanded','false');});}
function openModal(title,auth=false){closeDrawer();$('modal-title').textContent=title;$('modal').classList.toggle('auth-dialog',auth);if(!$('modal').open)$('modal').showModal();}
const checks=(entries,values,group)=>Object.entries(entries).map(([key,label])=>`<label class="check-row"><span>${label}</span><input type="checkbox" data-group="${group}" data-key="${key}" ${values[key]?'checked':''}></label>`).join('');
const group=(title,content)=>`<section class="panel-group" data-page-title="${title}">${content}</section>`;
const searchForm=()=>`<form id="search-form" class="stack"><label for="province-id">Поиск провинции по ID</label><div class="search-row"><input id="province-id" type="number" min="1" max="16777215" step="1" placeholder="ID" required><button type="submit">Найти</button></div></form>`;
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
  const drawer=$('drawer');if(drawer.hidden)return;
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
  if(current==='markers')host.innerHTML=group('Названия',checks({names:'Названия маркеров'},settings.markers,'markers'))+group('Типы',`<div class="check-grid">${checks(MARKERS,settings.markers,'markers')}</div><p class="hint">Маркеры пока не созданы.</p>`);
  if(current==='info')host.innerHTML=group('Поиск',searchForm())+group('Карта',`<div class="check-grid">${checks({ids:'ID провинций'},{ids:settings.showIds},'ids')}${checks({roads:INFO.roads,routes:INFO.routes},settings.information,'information')}</div>`)+group('Подписи',`<div class="check-grid">${checks(Object.fromEntries(Object.entries(INFO).filter(([k])=>!['roads','routes'].includes(k))),settings.information,'information')}</div>`);
  if(current==='tools')host.innerHTML=group('Инструмент',`<div class="tool-grid"><button data-tool="distance" aria-pressed="${toolMode==='distance'}">Расстояние</button><button data-tool="area" aria-pressed="${toolMode==='area'}">Площадь</button><button data-tool="coordinates" aria-pressed="${toolMode==='coordinates'}">Координаты</button><button id="copy-coordinates">Копировать точку</button></div>`)+group('Измерение',`<p class="hint">Две точки — расстояние. Три и более — площадь.</p><div id="tool-result" class="tool-result">${escape(lastToolResult||'Выберите инструмент')}</div><div class="tool-actions"><button id="finish-area">Завершить</button><button id="undo-point">Отменить точку</button><button id="clear-tool">Очистить</button></div>`)+group('Переход',`<form id="coordinate-form" class="stack"><label>Перейти к координатам</label><div class="coordinate-row"><input name="x" type="number" min="0" max="9999" step="any" placeholder="X" aria-label="Координата X" required><input name="y" type="number" min="0" max="9999" step="any" placeholder="Y" aria-label="Координата Y" required></div><button type="submit">Перейти</button></form>`);
  if(current==='legend'){
    const entries=categories.filter(c=>c.layer===settings.layer);
    let html=`<h3>${LAYERS[settings.layer]}</h3>`;
    if(entries.length)html+=entries.map(c=>`<div class="legend-row"><i class="legend-swatch" style="background:${/^#[0-9a-f]{6}$/i.test(c.color)?c.color:'#888'}"></i><span>${escape(c.name)}</span></div>`).join('');
    else if(['population','development'].includes(settings.layer)){
      const values=allProvinces.map(p=>settings.layer==='population'?(p.population==null?null:p.population/p.area):p.development).filter(v=>v!=null);
      html+=values.length?`<p>От ${Math.min(...values).toLocaleString('ru-RU')} до ${Math.max(...values).toLocaleString('ru-RU')}${settings.layer==='population'?' чел./km²':''}</p><div class="gradient-key"></div>`:'<p class="hint">Показатели пока не заполнены.</p>';
    }else html+='<p class="hint">Для выбранного слоя данные пока не назначены.</p>';
    host.innerHTML=group('Слой',html)+group('Территории','<div class="legend-row"><i class="legend-swatch" style="background:#ffe7d6"></i><span>Нейтральные территории</span></div><div class="legend-row"><i class="legend-swatch" style="background:#486370"></i><span>Море</span></div><div class="legend-row"><i class="legend-swatch" style="background:#1f87ad"></i><span>Озеро</span></div>');
  }
  if(current==='admin')host.innerHTML='<span class="badge">ADMIN</span><p class="hint">Панель доступна вашей роли. Инструменты управления государствами, объектами и игровыми механиками будут добавлены после уточнения требований.</p>';
  host.querySelectorAll('[data-layer]').forEach(b=>b.onclick=()=>{settings.layer=b.dataset.layer;save();renderDrawer();});
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
function togglePanel(key){
  if(key==='auth'){renderAuth();return;}
  if(key==='menu'){renderMenu('Профиль');return;}
  if(key==='admin'&&user?.role!=='admin')return;
  if(current===key){closeDrawer();return;}
  current=key;$('drawer-title').textContent=PANELS[key][0];$('drawer').className=`surface drawer ${PANELS[key][2]}`;$('drawer').hidden=false;
  document.querySelectorAll('.dock-button').forEach(b=>{b.classList.toggle('active',b.dataset.panel===key);b.setAttribute('aria-expanded',b.dataset.panel===key);});renderDrawer();
}
async function acceptUser(next){
  user=next;$('panel-admin').hidden=user?.role!=='admin';$('panel-auth').title=user?`Авторизация · ${user.nickname}`:'Авторизация';
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
function renderMenu(section){
  openModal('Меню');const host=$('modal-content');host.innerHTML=`<div class="menu-layout"><nav class="menu-tabs" aria-label="Разделы сайта">${MENU.map(name=>`<button data-section="${name}" class="${name===section?'active':''}">${name}</button>`).join('')}</nav><section id="menu-section" class="placeholder"></section></div>`;
  host.querySelectorAll('[data-section]').forEach(b=>b.onclick=()=>renderMenu(b.dataset.section));
  const content=$('menu-section');
  if(section==='Профиль'&&user)content.innerHTML=`<h3>${escape(user.nickname)}</h3><p>${escape(user.email)}</p><p class="hint">Роль: ${escape(user.role)}</p>`;
  else if(section==='Профиль')content.innerHTML='<h3>Профиль</h3><p class="hint">Войдите или зарегистрируйтесь, чтобы сохранять настройки карты в аккаунте.</p><button id="profile-login">Войти</button>';
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
  $('close-drawer').onclick=closeDrawer;$('close-modal').onclick=()=>$('modal').close();
  $('modal').addEventListener('click',e=>{if(e.target===$('modal'))$('modal').close();});
  const observer=new ResizeObserver(queueLayout);observer.observe($('selection'));observer.observe($('map-scale'));
  window.addEventListener('resize',queueLayout);
  window.addEventListener('keydown',e=>{if(e.key==='Escape'){closeDrawer();emit('map:tool','');toolMode='';}});
  window.addEventListener('tools:result',e=>{lastToolResult=e.detail;if($('tool-result'))$('tool-result').textContent=e.detail;queueLayout();});
  const reset=new URLSearchParams(location.hash.slice(1)).get('reset');if(reset){history.replaceState(null,'',location.pathname);renderAuth('reset',reset);}
}
export async function hydrateUI(data){categories=data.categories;allProvinces=data.provinces;try{await acceptUser((await api('auth/me')).user);}catch(e){showStatus(e.message,4000);}emit('map:settings',settings);}
