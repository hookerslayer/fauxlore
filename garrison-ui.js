import {garrisonApi} from './supabase-api.js?v=load-recovery-20261031';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const number=value=>Number(value||0).toLocaleString('ru-RU',{maximumFractionDigits:2});
const fortNames=['Нет','Форт','Крепость I','Крепость II','Крепость III'];
const wallNames=['Нет','Городские стены I','Городские стены II','Городские стены III'];
let selectedProvinceId=null;

export function renderGarrisonPanel(host,data,{stateId,notify,refresh,onMapChange}={}){
  if(!host)return;
  const provinces=data.provinces||[],owned=provinces.filter(p=>p.owned),neutral=provinces.filter(p=>p.neutral);
  const selected=provinces.find(p=>Number(p.id)===selectedProvinceId)||owned.find(p=>p.type==='Столичная')||owned[0]||neutral[0];
  selectedProvinceId=selected?.id||null;
  const projects=selected?.projects||[];
  const fort=Number(selected?.fort_level||0),wall=Number(selected?.wall_level||0);
  const fortUpkeep=p=>Math.max(0,([0,100,200,300,400][Number(p.fort_level)||0]||0)-(p.free_fort?300:0))+Math.max(0,([0,300,500,700][Number(p.wall_level)||0]||0)-(p.free_wall?300:0));
  const troopUpkeep=p=>(p.units||[]).reduce((sum,u)=>sum+Number(u.quantity)*Number(u.upkeep)*.4,0);
  const composition=p=>(p.units||[]).map(u=>`${escape(u.name)} × ${number(u.quantity)}`).join(', ')||'—';
  const provinceRow=p=>`<tr class="${p.id===selected?.id?'is-selected':''}"><td><button type="button" data-garrison-province="${p.id}" ${p.id===selected?.id?'aria-current="true"':''}>${escape(p.name)}</button></td><td>${escape(p.type)}</td><td>${number(p.used)} / ${number(p.capacity)}</td><td>${composition(p)}</td><td>${number(fortUpkeep(p))} G</td><td>${number(troopUpkeep(p))} G</td></tr>`;
  host.innerHTML=`<div class="stack garrison-panel"><section class="application-panel"><h4>Гарнизоны провинций</h4><p class="hint">Недвижимые войска. Лимит = развитие × коэффициент провинции + вместимость готовых укреплений. Найм стоит 70% обычной цены, содержание — 40%.</p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Провинция</th><th>Тип</th><th>Занято / лимит</th><th>Состав гарнизона</th><th>Содержание укреплений / ход</th><th>Содержание гарнизона / ход</th></tr></thead><tbody>${owned.map(provinceRow).join('')||'<tr><td colspan="6">Нет своих провинций.</td></tr>'}</tbody></table></div></section>${neutral.length?`<section class="application-panel"><h4>Нейтральные провинции у границы</h4><p class="hint">Строительство форта доступно во всплывающем окне провинции на карте.</p><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Провинция</th><th>Форт</th><th>Стройка</th><th></th></tr></thead><tbody>${neutral.map(p=>`<tr><td>${escape(p.name)}</td><td>${fortNames[p.fort_level]||'Нет'}</td><td>${p.projects?.length?`${p.projects[0].turns_remaining} ход.`:'—'}</td><td><button type="button" data-garrison-province="${p.id}">Управлять</button></td></tr>`).join('')}</tbody></table></div></section>`:''}${selected?`<section class="application-panel garrison-detail"><h4>${escape(selected.name)} · ${selected.neutral?'нейтральная провинция':escape(selected.type)}</h4><p><strong>${fortNames[fort]}</strong> · <strong>${wallNames[wall]}</strong>${selected.free_fort||selected.free_wall?' · стартовое укрепление без базового содержания':''}</p><p>Вместимость: <strong>${number(selected.used)} / ${number(selected.capacity)}</strong>${selected.neutral?' · собственный форт даёт право на гарнизон':''}</p>${projects.length?`<p class="hint">Строится: ${projects.map(project=>`${project.kind==='fort'?fortNames[project.target_level]:wallNames[project.target_level]} — осталось ${project.turns_remaining} ход.`).join(', ')}</p>`:''}<div class="table-scroll"><table class="state-data-table"><thead><tr><th>Юнит</th><th>Количество</th><th>Рекруты</th><th>Содержание / ход</th></tr></thead><tbody>${selected.units?.map(unit=>`<tr><td>${escape(unit.name)}</td><td>${number(unit.quantity)}</td><td>${number(unit.quantity*unit.recruits)}</td><td>${number(unit.quantity*unit.upkeep*.4)} G</td></tr>`).join('')||'<tr><td colspan="4">Гарнизон пуст.</td></tr>'}</tbody></table></div>${selected.owned||fort>0?`<form data-garrison-hire class="garrison-form"><h5>Нанять в гарнизон</h5><label class="field"><span>Юнит</span><select name="unit_id" required>${(data.units||[]).map(unit=>`<option value="${unit.id}" data-price="${unit.hire_cost}" data-recruits="${unit.recruit_cost}" data-upkeep="${unit.upkeep}">${escape(unit.name)} · ${number(unit.hire_cost*.7)} G · ${unit.recruit_cost} рекр.</option>`).join('')}</select></label><label class="field"><span>Количество</span><input name="quantity" type="number" min="1" max="100000" value="1" required></label><p class="hint" data-garrison-estimate></p><button type="submit" class="primary" ${(data.units||[]).length?'':'disabled'}>Нанять</button></form>`:''}</section>`:'<p class="hint">Провинций для гарнизона нет.</p>'}</div>`;
  if(selected?.owned&&(fort||wall||(selected.units||[]).length||projects.length)){
    const sponsor=selected.sponsor||'Корона';
    const choices=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
    const form=document.createElement('form');form.className='garrison-sponsor-form';
    form.innerHTML=`<h5>Плательщик гарнизона</h5><p class="hint">Найм, строительство и содержание оплачивает одна казна. Для перехода на сословное финансирование нужен резерв на два хода содержания. Командование остаётся государственным.</p><label class="field"><span>Казна</span><select name="estate">${choices.map(name=>`<option value="${name}" ${name===sponsor?'selected':''}>${name}</option>`).join('')}</select></label><p>Содержание: ${number(fortUpkeep(selected)+troopUpkeep(selected))} G/ход</p><button type="submit">Сохранить плательщика</button>`;
    host.querySelector('.garrison-detail [data-garrison-hire]')?.before(form);
    if(!form.isConnected)host.querySelector('.garrison-detail')?.append(form);
    form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;try{await garrisonApi('sponsor',stateId,selected.id,{estate:form.elements.estate.value});notify?.('Плательщик гарнизона сохранён');window.dispatchEvent(new Event('state:resources-changed'));await refresh();}catch(error){notify?.(error.message);button.disabled=false;}};
  }
  host.querySelectorAll('[data-garrison-province]').forEach(button=>button.onclick=()=>{selectedProvinceId=Number(button.dataset.garrisonProvince);renderGarrisonPanel(host,data,{stateId,notify,refresh,onMapChange});});
  const hire=host.querySelector('[data-garrison-hire]');
  if(hire){
    const estimate=()=>{const unit=(data.units||[]).find(item=>Number(item.id)===Number(hire.elements.unit_id.value));const count=Math.max(0,Number(hire.elements.quantity.value)||0);hire.querySelector('[data-garrison-estimate]').textContent=unit?`Итого: ${number(count*unit.hire_cost*.7)} G · ${number(count*unit.recruit_cost)} рекрутов · ${number(count*unit.upkeep*.4)} G/ход`:'Нет доступных юнитов';};
    hire.elements.unit_id.onchange=estimate;hire.elements.quantity.oninput=estimate;estimate();
    hire.onsubmit=async event=>{event.preventDefault();const unit=(data.units||[]).find(item=>Number(item.id)===Number(hire.elements.unit_id.value));const count=Number(hire.elements.quantity.value);if(!unit||!Number.isInteger(count)||count<1)return;
      if(!confirm(`Нанять ${count} × ${unit.name} в гарнизон провинции «${selected.name}» за ${number(count*unit.hire_cost*.7)} G и ${number(count*unit.recruit_cost)} рекрутов?`))return;
      await act('hire',{unit_id:unit.id,quantity:count});};
  }
  async function act(action,payload){
    host.querySelectorAll('button').forEach(button=>button.disabled=true);
    try{await garrisonApi(action,stateId,selected.id,payload);notify?.(action==='hire'?'Войска наняты в гарнизон':'Строительство началось');window.dispatchEvent(new Event('state:resources-changed'));window.dispatchEvent(new Event('map:refresh'));onMapChange?.();await refresh();}
    catch(error){notify?.(error.message);host.querySelectorAll('button').forEach(button=>button.disabled=false);}
  }
}
