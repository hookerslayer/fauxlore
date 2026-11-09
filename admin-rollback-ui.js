// Панель администратора: отмена строительства с возвратом денег.
// Сумма возврата берётся с сервера из сохранённой стоимости проекта.
import {adminRollbackApi} from './supabase-api.js?v=conquest-20261109b';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const money=value=>`${Number(value||0).toLocaleString('ru-RU')} G`;
const kindLabel=kind=>kind==='wall'?'Стены':'Крепость';

export async function renderAdminRollback(panel){
  const render=async()=>{
    try{
      const snapshot=await adminRollbackApi('snapshot');
      if(!panel.isConnected)return;
      const projects=snapshot.port_projects||[],ports=snapshot.ports||[],garrisons=snapshot.garrison_projects||[];
      const projectRows=projects.map(p=>`<tr><td>${escape(p.state_name||'—')}</td><td>${escape(p.province_name||'—')}</td><td>${money(p.cost)}</td><td>${Number(p.turns_remaining)}</td><td><button type="button" data-cancel-port-project="${Number(p.id)}">Отменить и вернуть</button></td></tr>`).join('')||'<tr><td colspan="5">Строящихся портов нет.</td></tr>';
      const portRows=ports.map(p=>`<tr><td>${escape(p.name)}</td><td>${escape(p.province_name||'—')}</td><td>${escape(p.state_name||'Нейтральный')}</td><td>${p.cost==null?'—':money(p.cost)}</td><td><button type="button" data-cancel-port="${Number(p.marker_id)}">Снести и вернуть</button></td></tr>`).join('')||'<tr><td colspan="5">Портов нет.</td></tr>';
      const garrisonRows=garrisons.map(g=>`<tr><td>${escape(g.state_name||'—')}</td><td>${escape(g.province_name||'—')}</td><td>${kindLabel(g.kind)} ${Number(g.target_level)}</td><td>${money(g.cost)}</td><td><button type="button" data-cancel-garrison="${Number(g.id)}">Отменить и вернуть</button></td></tr>`).join('')||'<tr><td colspan="5">Строящихся укреплений нет.</td></tr>';
      panel.innerHTML=`<h3>Откат строительства</h3><p class="hint">Отмена возвращает ровно ту сумму, которая была списана при начале стройки, и освобождает место для новой постройки.</p><p class="form-message" role="status"></p><h4>Строящиеся порты</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Государство</th><th>Провинция</th><th>Стоимость</th><th>Ходов</th><th></th></tr></thead><tbody>${projectRows}</tbody></table></div><h4>Построенные порты</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Порт</th><th>Провинция</th><th>Государство</th><th>Стоимость</th><th></th></tr></thead><tbody>${portRows}</tbody></table></div><h4>Стройки укреплений</h4><div class="table-scroll"><table class="state-data-table"><thead><tr><th>Государство</th><th>Провинция</th><th>Объект</th><th>Стоимость</th><th></th></tr></thead><tbody>${garrisonRows}</tbody></table></div>`;
      const message=panel.querySelector('[role=status]');
      const run=async(action,payload,question)=>{
        if(question&&!confirm(question))return;
        const buttons=[...panel.querySelectorAll('button')];buttons.forEach(button=>button.disabled=true);
        try{const result=await adminRollbackApi(action,payload);await render();window.dispatchEvent(new Event('map:refresh'));window.dispatchEvent(new Event('state:resources-changed'));return result;}
        catch(error){message.textContent=error.message;buttons.forEach(button=>button.disabled=false);}
      };
      panel.querySelectorAll('[data-cancel-port-project]').forEach(button=>button.onclick=()=>void run('cancel_port_project',{project_id:Number(button.dataset.cancelPortProject)},'Отменить строительство порта и вернуть деньги?'));
      panel.querySelectorAll('[data-cancel-port]').forEach(button=>button.onclick=()=>void run('cancel_port',{marker_id:Number(button.dataset.cancelPort)},'Снести порт и вернуть деньги?'));
      panel.querySelectorAll('[data-cancel-garrison]').forEach(button=>button.onclick=()=>void run('cancel_garrison_project',{project_id:Number(button.dataset.cancelGarrison)},'Отменить строительство укрепления и вернуть деньги?'));
    }catch(error){
      if(panel.isConnected)panel.innerHTML=`<h3>Откат строительства</h3><p class="form-message">${escape(error.message)}</p>`;
    }
  };
  await render();
}
