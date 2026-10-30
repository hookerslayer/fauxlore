import {wallApi,adminModifiersApi,wallVerdictManyApi} from './supabase-api.js?v=server-boundary-final-20261030';

const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date=value=>new Date(value).toLocaleString('ru-RU');
const avatar=(source,name)=>source?`<img class="wall-avatar" src="${escape(source)}" alt="">`:`<span class="wall-avatar wall-avatar-fallback">${escape((name||'?')[0])}</span>`;
const options=(rows,label='name')=>rows.map(row=>`<option value="${Number(row.id)}">${escape(row[label])}</option>`).join('');
const renderComment=comment=>`<div class="wall-comment">${avatar(comment.avatar,comment.author)}<div><strong>${escape(comment.author)} · ${escape(comment.role==='admin'?'Администратор':comment.state||'Игрок')}</strong><small>${date(comment.created_at)}</small><p>${escape(comment.body)}</p></div></div>`;

export async function renderWall(host,user,onChange=()=>{}){
  host.innerHTML='<p class="hint">Загружаю Стену…</p>';
  let posts=[],hasMore=false,adminCatalog=null;
  const refresh=async(append=false)=>{
    const previousCount=posts.length;
    const page=await wallApi('list',{offset:append?previousCount:0,limit:append?6:Math.max(6,previousCount+1)});if(!host.isConnected)return;
    if(append){posts=[...posts,...page.slice(0,5)];hasMore=page.length>5;}
    else{posts=page.slice(0,Math.max(5,previousCount));hasMore=page.length>posts.length;}
    const canPost=user?.role==='admin'||Boolean(user?.state_ids?.length);
    host.innerHTML=`<div class="wall-page"><div class="wall-intro"><h2>Стена</h2><p class="hint">Договоры, указы, реформы и игровые сводки.</p></div>${canPost?`<div class="wall-actions"><button type="button" data-compose-toggle aria-expanded="false">+ Написать пост</button></div><form class="application-panel wall-compose" hidden><label>Новая запись <textarea name="body" minlength="1500" maxlength="30000" required placeholder="Напишите пост от 1500 до 30000 символов"></textarea></label><div class="wall-compose-footer"><span data-count>0 / 30 000</span><label>Изображения (до двух, по 2 МБ) <input name="images" type="file" accept="image/jpeg,image/png,image/webp" multiple></label>${user?.role==='admin'?'':`<label class="wall-checkbox"><input name="needs_verdict" type="checkbox"> Требуется вердикт администратора</label>`}<button type="submit">Опубликовать${user?.role==='admin'?'':' · 3 ОП'}</button></div><p class="form-message" role="status"></p></form>`:`<p class="hint">Публиковать посты могут игроки с государством и администратор.</p>`}<div class="wall-feed">${posts.map(post=>{const long=post.body.length>4000,brief=long?post.body.split(/\r?\n/)[0].slice(0,4000).trimEnd():post.body;return `<article class="application-panel wall-post" data-post="${Number(post.id)}">${user?.role==='admin'?`<button type="button" class="wall-delete" data-delete-post aria-label="Удалить пост">Удалить</button>`:''}<header class="wall-author">${avatar(post.avatar,post.author)}<div><strong>${escape(post.author)}</strong><small>${escape(post.role==='admin'?'Администратор':post.state||'Игрок')} · ${date(post.created_at)}</small></div>${post.needs_verdict&&!post.verdict?'<span class="badge">Ожидает вердикта</span>':''}</header>${post.images?.length?`<div class="wall-images">${post.images.map(src=>`<img src="${escape(src)}" alt="Изображение к посту" loading="lazy">`).join('')}</div>`:''}<div class="wall-text wall-preview">${escape(brief)}${long?'…':''}</div>${long?`<div class="wall-text wall-full" hidden>${escape(post.body)}</div><button type="button" class="wall-expand" data-expand aria-expanded="false">Показать полностью</button>`:''}<div class="wall-reactions"><button type="button" data-reaction="like" class="${post.my_reaction==='like'?'active':''}">Нравится · ${Number(post.likes)}</button><button type="button" data-reaction="dislike" class="${post.my_reaction==='dislike'?'active':''}">Не нравится · ${Number(post.dislikes)}</button><span>Комментарии · ${post.comments.length}</span></div>${post.verdict?`<div class="wall-verdict"><strong>Вердикт администратора · ${escape(post.verdict.state)}</strong><p>${escape(post.verdict.body)}</p>${post.verdict.treasury_expense||post.verdict.prestige_expense?`<small>Расходы: ${Number(post.verdict.treasury_expense)} G; ${Number(post.verdict.prestige_expense)} ОП</small>`:''}</div>`:''}<div class="wall-comments">${post.comments.map(renderComment).join('')}</div>${user?`<form class="wall-comment-form"><textarea name="body" maxlength="3000" required placeholder="Написать комментарий"></textarea><button type="submit">Отправить</button></form>`:''}${user?.role==='admin'&&!post.verdict?`<details class="wall-verdict-editor" data-verdict-editor><summary>Вынести вердикт</summary><div data-verdict-form>Загружаю…</div></details>`:''}</article>`}).join('')||'<p class="hint">Публикаций пока нет.</p>'}</div>${hasMore?'<button type="button" data-wall-more>Показать следующие</button>':''}</div>`;
    const compose=host.querySelector('.wall-compose');
    if(compose){const toggle=host.querySelector("[data-compose-toggle]");toggle.onclick=()=>{compose.hidden=!compose.hidden;toggle.setAttribute("aria-expanded",String(!compose.hidden));if(!compose.hidden)compose.elements.body.focus();};compose.elements.body.oninput=()=>compose.querySelector('[data-count]').textContent=`${compose.elements.body.value.length.toLocaleString('ru-RU')} / 30 000`;compose.onsubmit=async event=>{event.preventDefault();const button=compose.querySelector('[type="submit"]');button.disabled=true;try{const files=[...compose.elements.images.files];if(files.length>2||files.some(file=>file.size>2*1024*1024||!['image/jpeg','image/png','image/webp'].includes(file.type)))throw Error('Допустимы два изображения JPG, PNG или WebP до 2 МБ каждое');const images=await Promise.all(files.map(file=>new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(Error('Не удалось прочитать изображение'));reader.readAsDataURL(file);})));await wallApi('create',{body:compose.elements.body.value,images,needs_verdict:Boolean(compose.elements.needs_verdict?.checked)});posts=[];onChange();await refresh();}catch(error){compose.querySelector('[role="status"]').textContent=error.message;button.disabled=false;}};}
    for(const card of host.querySelectorAll('[data-post]')){
      const postId=Number(card.dataset.post);
      const remove=card.querySelector('[data-delete-post]'); if(remove)remove.onclick=async()=>{if(!confirm('Удалить этот пост со Стены?'))return;remove.disabled=true;try{await wallApi('delete',{post_id:postId});posts=posts.filter(item=>Number(item.id)!==postId);onChange();await refresh();}catch(error){remove.disabled=false;remove.title=error.message;}}; const expand=card.querySelector('[data-expand]');if(expand)expand.onclick=()=>{const open=expand.getAttribute('aria-expanded')==='true';card.querySelector('.wall-preview').hidden=!open;card.querySelector('.wall-full').hidden=open;expand.setAttribute('aria-expanded',String(!open));expand.textContent=open?'Показать полностью':'Свернуть';};
      const post=posts.find(item=>Number(item.id)===postId);
      const reactionButtons=[...card.querySelectorAll('[data-reaction]')];
      reactionButtons.forEach(button=>button.onclick=async()=>{
        reactionButtons.forEach(item=>item.disabled=true);
        try{
          const previous=post.my_reaction;
          const next=previous===button.dataset.reaction?null:button.dataset.reaction;
          await wallApi('react',{post_id:postId,reaction:button.dataset.reaction});
          if(previous==='like')post.likes=Math.max(0,Number(post.likes)-1);
          if(previous==='dislike')post.dislikes=Math.max(0,Number(post.dislikes)-1);
          if(next==='like')post.likes=Number(post.likes)+1;
          if(next==='dislike')post.dislikes=Number(post.dislikes)+1;
          post.my_reaction=next;
          reactionButtons.forEach(item=>{
            const reaction=item.dataset.reaction;
            item.classList.toggle('active',reaction===next);
            item.textContent=`${reaction==='like'?'Нравится':'Не нравится'} · ${Number(reaction==='like'?post.likes:post.dislikes)}`;
            item.removeAttribute('title');
          });
        }catch(error){button.title=error.message;}
        finally{reactionButtons.forEach(item=>item.disabled=false);}
      });
      const comment=card.querySelector('.wall-comment-form');if(comment)comment.onsubmit=async event=>{
        event.preventDefault();
        const button=comment.querySelector('button'),body=comment.elements.body.value;
        button.disabled=true;
        try{
          const created=await wallApi('comment',{post_id:postId,body});
          let updated=null;
          try{
            const position=posts.findIndex(item=>Number(item.id)===postId);
            const page=await wallApi('list',{offset:position,limit:1});
            updated=page.find(item=>Number(item.id)===postId)||null;
          }catch{}
          if(updated){
            post.comments=updated.comments;
            card.querySelector('.wall-comments').innerHTML=post.comments.map(renderComment).join('');
          }else{
            const fallback={id:created.id,body,author:user.nickname,avatar:user.avatar_url||null,role:user.role,state:null,created_at:new Date().toISOString()};
            post.comments.push(fallback);
            card.querySelector('.wall-comments').insertAdjacentHTML('beforeend',renderComment(fallback));
          }
          card.querySelector('.wall-reactions span').textContent=`Комментарии · ${post.comments.length}`;
          comment.reset();
        }catch(error){
          comment.elements.body.setCustomValidity(error.message);
          comment.reportValidity();
          comment.elements.body.setCustomValidity('');
        }finally{button.disabled=false;}
      };
      const editor=card.querySelector('[data-verdict-editor]');if(editor)editor.ontoggle=async()=>{if(!editor.open||editor.dataset.ready)return;try{adminCatalog??=await adminModifiersApi('snapshot');editor.dataset.ready='1';const states=adminCatalog.states||[],defs=adminCatalog.definitions||[];editor.querySelector('[data-verdict-form]').innerHTML=`<form class="wall-verdict-form"><label>Государства <select name="state_ids" multiple size="4" required>${options(states)}</select></label><label>Текст вердикта <textarea name="body" maxlength="10000" required></textarea></label><label>Расход Казны, G <input name="treasury_expense" type="number" min="0" step="1" value="0"></label><label>Расход Престижа, ОП <input name="prestige_expense" type="number" min="0" step="1" value="0"></label><div data-effect-rows></div><button type="button" data-add-effect>Добавить модификатор</button><button type="submit">Сохранить вердикт</button><p class="form-message" role="status"></p></form>`;const form=editor.querySelector('form');form.querySelector('[data-add-effect]').onclick=()=>{const row=document.createElement('div');row.className='wall-effect-row';row.innerHTML=`<label>Эффект <select name="definition_index">${defs.map((d,i)=>`<option value="${i}">${escape(d.effect)} · ${escape(d.source)}</option>`).join('')}</select></label><label>Значение <input name="value" type="number" step="any" required></label><label>Срок, ходов <input name="duration_turns" type="number" min="1" max="10000" step="1" placeholder="Постоянно"></label><button type="button">Убрать</button>`;const select=row.querySelector('select'),value=row.querySelector('[name="value"]');select.onchange=()=>{const d=defs[Number(select.value)];value.value=['%','п.п.'].includes(d.unit)?Number(d.value)*100:d.value;};select.onchange();row.querySelector('button').onclick=()=>row.remove();form.querySelector('[data-effect-rows]').append(row);};form.onsubmit=async event=>{event.preventDefault();const button=form.querySelector('[type="submit"]');button.disabled=true;try{const modifiers=[...form.querySelectorAll('.wall-effect-row')].map(row=>{const i=Number(row.querySelector('select').value),d=defs[i],entered=Number(row.querySelector('[name="value"]').value);return {definition_index:i,value:['%','п.п.'].includes(d.unit)?entered/100:entered,duration_turns:row.querySelector('[name="duration_turns"]').value?Number(row.querySelector('[name="duration_turns"]').value):null};});await wallVerdictManyApi({post_id:postId,state_ids:[...form.elements.state_ids.selectedOptions].map(option=>Number(option.value)),body:form.elements.body.value,treasury_expense:Number(form.elements.treasury_expense.value),prestige_expense:Number(form.elements.prestige_expense.value),modifiers});onChange();await refresh();}catch(error){form.querySelector('[role="status"]').textContent=error.message;button.disabled=false;}};}catch(error){editor.querySelector('[data-verdict-form]').textContent=error.message;}};
    }
    const more=host.querySelector('[data-wall-more]');if(more)more.onclick=async()=>{more.disabled=true;try{await refresh(true);}catch(error){more.disabled=false;more.textContent='Ошибка загрузки — повторить';more.title=error.message;}};
  };
  try{await refresh();}catch(error){host.innerHTML=`<p class="form-message">Не удалось загрузить Стену: ${escape(error.message)}</p>`;}
}
