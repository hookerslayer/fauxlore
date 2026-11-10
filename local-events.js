import {localEventsApi} from './supabase-api.js?v=conquest-20261110c';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const localKeys=new Set(['tax_efficiency','production','trade_influence','population_growth','recruit_growth','recruit_limit','development']);
const formatEffect=effect=>`${effect.scope==='province'?'Провинция':'Государство'}: ${effect.effect} · ${(['%','п.п.'].includes(effect.unit)?Number(effect.value)*100:Number(effect.value)).toLocaleString('ru-RU')} ${effect.unit}`;

// Черновик формы: выбор провинции на карте уводит со страницы профиля и
// размонтирует панель, поэтому введённые значения переживают перерисовку.
let eventDraft=null;
const readEffects=container=>[...container.querySelectorAll('[data-event-effect]')].map(row=>({
  scope:row.querySelector('[data-scope]').value,
  definition:Number(row.querySelector('[data-definition]').value),
  value:row.querySelector('[data-value]').value,
}));

export async function renderLocalEventAdmin(panel){
  try{
    const [catalog,events]=await Promise.all([localEventsApi('catalog'),localEventsApi('list')]);
    if(!panel.isConnected)return;
    const allowedProvinces=new Set(catalog.provinces.map(p=>Number(p.id)));
    const visibleEvents=events.filter(e=>allowedProvinces.has(Number(e.province_id)));
    const draft=eventDraft||{};
    const provinceLabel=draft.province?`${escape(draft.province.name)} · ${Number(draft.province.id)}`:'Провинция не выбрана';
    panel.innerHTML=`<h3>Создание местных событий</h3><form data-event-form class="stack"><div class="inline-actions"><button type="button" data-pick-province>Выбрать провинцию на карте</button><strong data-province-label>${provinceLabel}</strong></div><p class="hint">Провинция выбирается щелчком по карте: нажмите кнопку, укажите провинцию и вернитесь к форме.</p><input type="hidden" name="province_id" value="${draft.province?Number(draft.province.id):''}"><label>Название <input name="title" maxlength="120" required value="${escape(draft.title||'')}"></label><label>Описание <textarea name="description" maxlength="4000" rows="3">${escape(draft.description||'')}</textarea></label><label>Срок, ходов <input name="duration_turns" type="number" min="1" max="10000" step="1" placeholder="Постоянно" value="${escape(draft.duration||'')}"></label><div data-event-effects></div><div class="inline-actions"><button type="button" data-add-effect>Добавить эффект</button><button class="primary" type="submit">Создать событие</button><button type="button" data-reset-event>Сбросить</button></div><p class="form-message" role="status"></p></form><h4>Активные события</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Событие</th><th>Провинция</th><th>Срок</th><th></th></tr></thead><tbody>${visibleEvents.map(e=>`<tr><td>${escape(e.title)}</td><td>${escape(e.province_name)} · ${Number(e.province_id)}</td><td>${e.remaining_turns===null?'Постоянное':`${Number(e.remaining_turns)} ход.`}</td><td><button type="button" data-end-event="${Number(e.id)}">Закончить</button></td></tr>`).join('')||'<tr><td colspan="4">Активных событий нет.</td></tr>'}</tbody></table></div>`;
    const form=panel.querySelector('[data-event-form]'),container=panel.querySelector('[data-event-effects]');
    const provinceInput=form.elements.province_id,provinceName=panel.querySelector('[data-province-label]');
    const add=(effect)=>{
      const row=document.createElement('div');
      row.className='inline-actions';row.dataset.eventEffect='';
      row.innerHTML=`<label>Область <select data-scope><option value="province">Провинция</option><option value="state">Государство владельца</option></select></label><label>Эффект <select data-definition></select></label><label>Значение <input data-value type="number" step="any" required></label><button type="button" data-remove aria-label="Удалить эффект">×</button>`;
      container.append(row);
      const scope=row.querySelector('[data-scope]'),select=row.querySelector('[data-definition]'),valueInput=row.querySelector('[data-value]');
      const fill=()=>{select.innerHTML=catalog.definitions.map((d,i)=>({d,i})).filter(({d})=>scope.value==='state'||localKeys.has(d.key)).map(({d,i})=>`<option value="${i}">${escape(d.effect)} · ${escape(d.unit)}</option>`).join('');};
      scope.onchange=fill;
      row.querySelector('[data-remove]').onclick=()=>row.remove();
      if(effect){scope.value=effect.scope;fill();select.value=String(effect.definition);valueInput.value=effect.value;}
      else fill();
    };
    panel.querySelector('[data-add-effect]').onclick=()=>add();
    if(draft.effects?.length)draft.effects.forEach(effect=>add(effect));else add();
    panel.querySelector('[data-pick-province]').onclick=()=>{
      eventDraft={province:eventDraft?.province||null,title:form.elements.title.value,description:form.elements.description.value,duration:form.elements.duration_turns.value,effects:readEffects(container)};
      window.dispatchEvent(new CustomEvent('local-event:pick',{detail:{active:true}}));
      window.dispatchEvent(new CustomEvent('ui:show-map'));
    };
    panel.querySelector('[data-reset-event]').onclick=()=>{eventDraft=null;void renderLocalEventAdmin(panel);};
    form.onsubmit=async event=>{
      event.preventDefault();
      const button=form.querySelector('[type=submit]'),status=form.querySelector('[role=status]');
      if(!provinceInput.value){status.textContent='Выберите провинцию на карте.';return;}
      const rows=[...container.querySelectorAll('[data-event-effect]')];
      if(!rows.length){status.textContent='Добавьте хотя бы один эффект.';return;}
      const effects=rows.map(row=>{const d=catalog.definitions[Number(row.querySelector('[data-definition]').value)];return {...d,scope:row.querySelector('[data-scope]').value,value:Number(row.querySelector('[data-value]').value)/(['%','п.п.'].includes(d.unit)?100:1)};});
      button.disabled=true;
      try{
        await localEventsApi('create',{province_id:Number(provinceInput.value),title:form.elements.title.value,description:form.elements.description.value,duration_turns:form.elements.duration_turns.value?Number(form.elements.duration_turns.value):null,effects});
        eventDraft=null;window.dispatchEvent(new Event('map:refresh'));await renderLocalEventAdmin(panel);
      }catch(error){status.textContent=error.message;button.disabled=false;}
    };
    panel.querySelectorAll('[data-end-event]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{await localEventsApi('end',{event_id:Number(button.dataset.endEvent)});window.dispatchEvent(new Event('map:refresh'));await renderLocalEventAdmin(panel);}catch(error){button.disabled=false;form.querySelector('[role=status]').textContent=error.message;}});
  }catch(error){if(panel.isConnected)panel.innerHTML=`<h3>Создание местных событий</h3><p class="form-message">${escape(error.message)}</p>`;}
}

// Возврат к форме после выбора на карте или отмены по Esc.
window.addEventListener('local-event:province-picked',event=>{
  const province=event.detail||{};
  eventDraft={...(eventDraft||{}),province:{id:Number(province.id),name:String(province.name??'')}};
  window.dispatchEvent(new CustomEvent('ui:open-profile'));
});
window.addEventListener('local-event:pick-cancelled',()=>{window.dispatchEvent(new CustomEvent('ui:open-profile'));});

let eventPopover=null;
export function closeLocalEvent(){
  if(!eventPopover)return;
  eventPopover.remove();eventPopover=null;
  window.dispatchEvent(new Event('map:local-event-closed'));
}
export function positionLocalEvent({x,y,visible=true}){
  if(!eventPopover)return;
  eventPopover.hidden=!visible;if(!visible)return;
  const margin=8,gap=14,rect=eventPopover.getBoundingClientRect();
  const left=x+gap+rect.width<=innerWidth-margin?x+gap:x-gap-rect.width;
  const top=y-rect.height/2;
  eventPopover.style.left=`${Math.max(margin,Math.min(innerWidth-rect.width-margin,left))}px`;
  eventPopover.style.top=`${Math.max(margin,Math.min(innerHeight-rect.height-margin,top))}px`;
}
export function showLocalEvent(event,position){
  closeLocalEvent();
  const box=document.createElement('section');box.className='surface local-event-popover';box.setAttribute('role','dialog');box.setAttribute('aria-label','Местное событие');
  box.innerHTML=`<header><h2>${escape(event.title)}</h2><button type="button" class="icon-button" aria-label="Закрыть событие">×</button></header><div class="local-event-popover-content"><p><strong>Провинция:</strong> ${escape(event.province_name)} · ${Number(event.province_id)}</p><p class="local-event-description">${escape(event.description)}</p><p><strong>Срок:</strong> ${event.remaining_turns===null?'Постоянное':`${Number(event.remaining_turns)} ход.`}</p><h3>Эффекты</h3><ul>${event.effects.map(e=>`<li>${escape(formatEffect(e))}</li>`).join('')}</ul></div>`;
  box.querySelector('button').onclick=closeLocalEvent;document.body.append(box);eventPopover=box;positionLocalEvent(position);box.querySelector('button').focus({preventScroll:true});
}
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&eventPopover){event.preventDefault();closeLocalEvent();}});
