const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const reactionLabels={laugh:['😂','Смех'],like:['👍','Лайк'],dislike:['👎','Дизлайк']};
const mounts=new Map();let pollTimer=0;

function roleName(role){return role==='admin'?'Администратор':'Игрок';}
function avatar(user){return user.avatar_url?`<img class="chat-avatar" src="${escape(user.avatar_url)}" alt="${escape((user.nickname||'?').slice(0,1).toUpperCase())}" data-avatar-fallback="${escape((user.nickname||'?').slice(0,1).toUpperCase())}">`:`<span class="chat-avatar chat-avatar-fallback">${escape((user.nickname||'?').slice(0,1).toUpperCase())}</span>`;}

function messageMarkup(message,canModerate){
  const reactions=Object.entries(reactionLabels).map(([key,[icon,label]])=>`<button type="button" class="chat-reaction ${message.my_reaction===key?'active':''}" data-action="react" data-id="${message.id}" data-reaction="${key}" aria-label="${label}" title="${label}" ${message.deleted?'disabled':''}>${icon}<span>${message.reactions?.[key]||0}</span></button>`).join('');
  const controls=canModerate&&!message.deleted&&message.author.role!=='admin'?`<div class="chat-mod-controls"><button type="button" data-action="mute" data-user="${message.author.id}" data-banned="${message.author_banned}">${message.author_banned?'Разрешить писать':'Запретить писать'}</button><button type="button" data-action="delete" data-id="${message.id}">Удалить</button></div>`:canModerate&&!message.deleted?`<div class="chat-mod-controls"><button type="button" data-action="delete" data-id="${message.id}">Удалить</button></div>`:'';
  const time=new Date(message.created_at).toLocaleString('ru-RU',{dateStyle:'short',timeStyle:'short'});
  return `<article class="chat-message ${message.deleted?'deleted':''}"><header>${avatar(message.author)}<div class="chat-author"><strong>${escape(message.author.nickname)}</strong><span>${roleName(message.author.role)} · Репутация ${message.author.reputation}</span></div><time>${escape(time)}</time></header>${message.text?`<p class="chat-message-text">${escape(message.text)}</p>`:''}${message.image_url?`<img class="chat-image" src="${escape(message.image_url)}" alt="Изображение в сообщении" loading="lazy">`:''}<div class="chat-reactions">${reactions}</div>${controls}</article>`;
}

function draw(entry){
  if(!entry.host.isConnected)return;
  if(!entry.user()){
    entry.host.innerHTML='<div class="chat-login"><p>Войдите в аккаунт, чтобы читать и отправлять сообщения.</p><button data-chat-login>Войти</button></div>';
    entry.host.querySelector('[data-chat-login]').onclick=entry.onLogin;
    return;
  }
  if(!entry.data){entry.host.innerHTML='<div class="chat-loading">Загружаю сообщения…</div>';return;}
  const current=entry.data.current_user;
  const testMode=current.is_test_profile?`<div class="chat-test-mode">Тестовый профиль: ${escape(current.nickname)}</div>`:'';
  entry.host.innerHTML=`${testMode}<div class="chat-messages" role="log" aria-label="Сообщения чата">${entry.data.messages.length?entry.data.messages.map(m=>messageMarkup(m,entry.data.can_moderate)).join(''):'<p class="chat-empty">Пока нет сообщений. Начните разговор.</p>'}</div><form class="chat-compose"><textarea name="text" maxlength="2000" rows="2" placeholder="Написать сообщение…" aria-label="Текст сообщения"></textarea><div class="chat-compose-actions"><label class="chat-attach">Изображение<input name="image" type="file" accept="image/png,image/jpeg,image/gif,image/webp" hidden></label><span class="chat-file-name"></span><button class="primary" type="submit" ${entry.data.muted?'disabled':''}>Отправить</button></div><p class="chat-warning" ${entry.data.muted?'':'hidden'}>Для этого профиля отправка сообщений отключена модератором.</p></form>`;
  entry.host.querySelectorAll('img[data-avatar-fallback]').forEach(image=>image.onerror=()=>{const fallback=document.createElement('span');fallback.className='chat-avatar chat-avatar-fallback';fallback.textContent=image.dataset.avatarFallback;fallback.setAttribute('aria-label','Аватар недоступен');image.replaceWith(fallback);});
  const messages=entry.host.querySelector('.chat-messages');messages.scrollTop=messages.scrollHeight;
  const imageInput=entry.host.querySelector('.chat-compose input[type="file"][name="image"]');
  imageInput.onchange=e=>{const file=e.currentTarget.files?.item(0);if(!file){entry.host.querySelector('.chat-file-name').textContent='';return;}if(file.size>2*1024*1024){entry.notify('Изображение должно быть не больше 2 МБ',4000);e.currentTarget.value='';entry.host.querySelector('.chat-file-name').textContent='';return;}entry.host.querySelector('.chat-file-name').textContent=file.name;};
  entry.host.querySelector('.chat-compose').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,button=form.querySelector('[type=submit]'),file=imageInput.files?.item(0),text=form.elements.text.value;if(!text.trim()&&!file){entry.notify('Введите сообщение или выберите изображение',3000);return;}button.disabled=true;try{const image_data=file?await readDataUrl(file):null;if(file&&!image_data?.startsWith('data:image/'))throw new Error('Не удалось прочитать выбранное изображение');const result=await entry.api('chat/messages',{method:'POST',body:JSON.stringify({text,image_data,image_selected:Boolean(file)})});if(file&&!result.image_attached)throw new Error('Сервер не получил изображение. Выберите файл и отправьте ещё раз.');form.reset();entry.host.querySelector('.chat-file-name').textContent='';await refreshAll();}catch(error){entry.notify(error.message,5000);}finally{button.disabled=false;}};
  entry.host.querySelectorAll('[data-action]').forEach(button=>button.onclick=async()=>{
    const {action,id,reaction,user,banned}=button.dataset;button.disabled=true;
    try{
      if(action==='react')await entry.api(`chat/messages/${id}/reaction`,{method:'POST',body:JSON.stringify({reaction})});
      if(action==='delete'){if(!confirm('Удалить сообщение?'))return;await entry.api(`admin/chat/messages/${id}`,{method:'DELETE',body:'{}'});}
      if(action==='mute')await entry.api(`admin/chat/users/${user}/ban`,{method:'POST',body:JSON.stringify({banned:banned!=='true'})});
      await refreshAll();
    }catch(error){entry.notify(error.message,5000);}finally{button.disabled=false;}
  });
}

function readDataUrl(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(new Error('Не удалось прочитать изображение'));reader.readAsDataURL(file);});}

async function refresh(entry){
  if(!entry.host.isConnected||!entry.user())return;
  try{entry.data=await entry.api('chat/messages');draw(entry);}catch(error){entry.host.innerHTML=`<p class="chat-error">${escape(error.message)}</p>`;}
}

async function refreshAll(){await Promise.all([...mounts.values()].map(refresh));}
function startPolling(){if(!pollTimer)pollTimer=setInterval(()=>refreshAll(),8000);}

export function mountChat(host,options){
  unmountChat(host);
  const entry={host,...options,data:null};mounts.set(host,entry);startPolling();draw(entry);refresh(entry);
}

export function unmountChat(host){mounts.delete(host);if(!mounts.size&&pollTimer){clearInterval(pollTimer);pollTimer=0;}}
