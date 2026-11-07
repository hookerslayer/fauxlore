// Панель администратора: армии и флотилии без государства, а также гарнизоны
// нейтральных маркеров. Список провинций приходит только для провинций с
// нейтральными маркерами — там нейтральные силы и размещаются.
import {neutralForcesApi} from './supabase-api.js?v=neutral-forces-20261107';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const domainLabel=value=>value==='naval'?'Флотилия':'Армия';
const unitLabel=unit=>`${escape(unit.name)} · ${Number(unit.hire_cost).toLocaleString('ru-RU')} G`;

function provinceOptions(list){
  return list.map(p=>`<option value="${Number(p.id)}">${escape(p.name)} · ${Number(p.id)}</option>`).join('')||'<option value="">Нет доступных провинций</option>';
}

function unitOptions(list){
  return list.map(u=>`<option value="${Number(u.id)}">${unitLabel(u)}</option>`).join('')||'<option value="">Нет юнитов</option>';
}

export async function renderNeutralForces(panel){
  const render=async()=>{
    try{
      const snapshot=await neutralForcesApi('snapshot');
      if(!panel.isConnected)return;
      const formations=snapshot.formations||[];
      const provinces=snapshot.provinces||[];
      const catalog=snapshot.catalog||[];
      const land=provinces.filter(p=>p.kind==='land');
      const sea=provinces.filter(p=>p.kind==='sea');
      const landUnits=catalog.filter(u=>u.domain!=='naval');
      const seaUnits=catalog.filter(u=>u.domain==='naval');
      const formationRows=formations.map(f=>{
        const units=(f.units||[]).map(u=>`${escape(u.name)} × ${Number(u.quantity).toLocaleString('ru-RU')}`).join(', ')||'—';
        const pool=f.domain==='naval'?seaUnits:landUnits;
        return `<tr><td>${escape(f.name)}</td><td>${domainLabel(f.domain)}</td><td>${escape(f.province_name||'—')}</td><td>${units}</td><td><form class="inline-actions" data-neutral-hire="${Number(f.id)}"><select name="unit_id" aria-label="Юнит">${unitOptions(pool)}</select><input name="quantity" type="number" min="1" max="100000" step="1" value="1" aria-label="Количество"><button type="submit">Добавить</button></form>${(f.units||[]).length?'':`<button type="button" data-neutral-delete="${Number(f.id)}">Удалить</button>`}</td></tr>`;
      }).join('')||'<tr><td colspan="5">Нейтральных формирований нет.</td></tr>';
      const garrisonRows=land.map(p=>{
        const units=(p.garrison||[]).map(u=>`<span class="inline-actions">${escape(u.name)} × ${Number(u.quantity).toLocaleString('ru-RU')}<button type="button" data-garrison-remove="${Number(p.id)}:${Number(u.unit_id)}" aria-label="Убрать юнита">×</button></span>`).join(', ')||'—';
        return `<tr><td>${escape(p.name)}</td><td>${(p.markers||[]).map(m=>escape(m)).join(', ')||'—'}</td><td>${units}</td><td>${Number(p.capacity||0).toLocaleString('ru-RU')}</td><td><form class="inline-actions" data-neutral-garrison="${Number(p.id)}"><select name="unit_id" aria-label="Юнит">${unitOptions(landUnits)}</select><input name="quantity" type="number" min="1" max="100000" step="1" value="1" aria-label="Количество"><button type="submit">В гарнизон</button></form></td></tr>`;
      }).join('')||'<tr><td colspan="5">Провинций с нейтральными маркерами нет.</td></tr>';
      panel.innerHTML=`<h3>Нейтральные силы</h3><p class="hint">Армии, флотилии и гарнизоны без государства. Содержание за них не списывается, автоматические расчёты боёв их не затрагивают — ими распоряжается администратор.</p><form data-neutral-create class="stack"><div class="inline-actions"><label>Название <input name="name" minlength="2" maxlength="100" required></label><label>Тип <select name="domain"><option value="land">Армия</option><option value="naval">Флотилия</option></select></label><label>Провинция <select name="province_id" required data-neutral-province>${provinceOptions(land)}</select></label><button class="primary" type="submit">Создать</button></div><p class="form-message" role="status"></p></form><h4>Формирования</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Название</th><th>Тип</th><th>Провинция</th><th>Состав</th><th>Действия</th></tr></thead><tbody>${formationRows}</tbody></table></div><h4>Гарнизоны нейтральных маркеров</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Провинция</th><th>Маркеры</th><th>Гарнизон</th><th>Лимит</th><th>Действия</th></tr></thead><tbody>${garrisonRows}</tbody></table></div>`;
      const create=panel.querySelector('[data-neutral-create]');
      const provinceSelect=create.querySelector('[data-neutral-province]');
      create.elements.domain.onchange=()=>{provinceSelect.innerHTML=provinceOptions(create.elements.domain.value==='naval'?sea:land);provinceSelect.value=provinceSelect.querySelector('option')?.value||'';};
      const message=create.querySelector('[role=status]');
      const run=async(action,payload,form)=>{
        const buttons=[...panel.querySelectorAll('button')];buttons.forEach(button=>button.disabled=true);
        try{await neutralForcesApi(action,payload);await render();}
        catch(error){(form?.querySelector('[role=status]')||message).textContent=error.message;buttons.forEach(button=>button.disabled=false);}
      };
      create.onsubmit=event=>{
        event.preventDefault();
        const data=new FormData(create);
        if(!data.get('province_id')){message.textContent='Нет провинции с нейтральным маркером.';return;}
        void run('create_formation',{name:data.get('name'),domain:data.get('domain'),province_id:Number(data.get('province_id'))},create);
      };
      panel.querySelectorAll('[data-neutral-hire]').forEach(form=>form.onsubmit=event=>{
        event.preventDefault();const data=new FormData(form),button=form.querySelector('button');button.disabled=true;
        void run('hire_unit',{formation_id:Number(form.dataset.neutralHire),unit_id:Number(data.get('unit_id')),quantity:Number(data.get('quantity'))});
      });
      panel.querySelectorAll('[data-neutral-delete]').forEach(button=>button.onclick=()=>{
        if(!confirm('Удалить нейтральное формирование?'))return;
        void run('delete_formation',{formation_id:Number(button.dataset.neutralDelete)});
      });
      panel.querySelectorAll('[data-neutral-garrison]').forEach(form=>form.onsubmit=event=>{
        event.preventDefault();const data=new FormData(form),button=form.querySelector('button');button.disabled=true;
        void run('garrison_add',{province_id:Number(form.dataset.neutralGarrison),unit_id:Number(data.get('unit_id')),quantity:Number(data.get('quantity'))});
      });
      panel.querySelectorAll('[data-garrison-remove]').forEach(button=>button.onclick=()=>{
        const[provinceId,unitId]=button.dataset.garrisonRemove.split(':').map(Number);
        void run('garrison_remove',{province_id:provinceId,unit_id:unitId});
      });
    }catch(error){
      if(panel.isConnected)panel.innerHTML=`<h3>Нейтральные силы</h3><p class="form-message">${escape(error.message)}</p>`;
    }
  };
  await render();
}
