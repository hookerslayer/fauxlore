function doGet(event){
  try{
    if(event.parameter.state&&(event.parameter.code||event.parameter.error))return oauthCallback_(event);
    if(event.parameter.bridge==='1'){
      if(!allowedOrigin_(event.parameter.origin)||!/^[0-9a-f]{64}$/.test(event.parameter.channel||''))fail_(403,'Адрес карты не разрешён');
      const template=HtmlService.createTemplateFromFile('Bridge');template.originJson=JSON.stringify(event.parameter.origin).replace(/</g,'\\u003c');template.channelJson=JSON.stringify(event.parameter.channel);
      return template.evaluate().setTitle('Fauxlore API').setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
    }
    return ContentService.createTextOutput(JSON.stringify({ok:true,service:'Fauxlore Google backend',database:'google-sheets'})).setMimeType(ContentService.MimeType.JSON);
  }catch(error){return HtmlService.createHtmlOutput('<p>Не удалось открыть сервис. Вернитесь на карту и повторите действие.</p>');}
}
function fxRpc(request){
  let lock;
  try{
    if(!request||typeof request!=='object'||typeof request.path!=='string'||request.path.length>150||!['GET','POST','PATCH','PUT','DELETE'].includes(request.method))fail_(400,'Некорректный запрос');
    if(!allowedOrigin_(request.origin))fail_(403,'Адрес карты не разрешён');
    if(JSON.stringify(request).length>2900000)fail_(413,'Слишком большой запрос');
    request.body=request.body||{};
    if(request.path==='auth/start'&&request.method==='POST')return {ok:true,data:authStart_(request.body)};
    const writing=request.method!=='GET';
    // Read requests share the lock too: no reader observes the middle of a command.
    lock=LockService.getScriptLock();if(!lock.tryLock(20000))fail_(503,'Сервис занят. Повторите запрос.');
    const db=new Store_();
    let user=null,receiptKey=null,fingerprint=null;
    if(writing&&request.path!=='auth/complete'){
      user=require_(db,request,request.path.startsWith('admin/'));
      if(!/^[0-9a-f-]{32,64}$/.test(request.request_id||''))fail_(400,'Нужен идентификатор команды');
      receiptKey=user.id+':'+request.request_id;fingerprint=hash_(JSON.stringify([request.method,request.path,request.body,request.test_profile||null]));
      const previous=db.rows('_operations').find(r=>r.id===receiptKey);
      if(previous){if(previous.request_hash!==fingerprint)fail_(409,'Идентификатор команды уже использован');const serialized=String(previous.result_json).startsWith('@blob:')?Utilities.newBlob(Utilities.base64Decode(db.blob(previous.result_json))).getDataAsString():previous.result_json;return {ok:true,data:JSON.parse(serialized)};}
    }
    const result=route_(db,request);
    if(writing){
      if(receiptKey){let serialized=JSON.stringify(result);if(serialized.length>30000)serialized=db.putBlob(Utilities.base64Encode(serialized,Utilities.Charset.UTF_8));db.add('_operations',{id:receiptKey,account_id:user.id,request_hash:fingerprint,result_json:serialized,created_at:now_()});}
      if(request.path.startsWith('admin/provinces')||request.path.startsWith('admin/markers')||request.path.startsWith('provinces/'))db.set('data_revision',(db.get('data_revision')||0)+1);
      db.commit();
    }
    return {ok:true,data:result};
  }catch(error){return {ok:false,status:error.status||500,error:error.status?error.message:'Не удалось выполнить запрос. Проверьте журнал Apps Script.'};}
  finally{if(lock)lock.releaseLock();}
}
function route_(db,r){
  const path=r.path,method=r.method,b=r.body;
  if(path==='health'&&method==='GET')return {ok:true,database:'google-sheets'};
  if(path==='map'&&method==='GET')return mapData_(db);
  if(path==='auth/me'&&method==='GET')return {user:publicUser_(db,user_(db,r.token))};
  if(path==='auth/complete'&&method==='POST')return authComplete_(db,b,r.origin);
  if(path==='auth/logout'&&method==='POST'){db.remove('sessions',s=>s.token_hash===hash_(r.token));return {ok:true};}
  const user=require_(db,r,path.startsWith('admin/'));
  if(path==='profile'&&method==='GET')return publicUser_(db,actor_(db,r));
  if(path==='profile/avatar'&&method==='POST'){const actor=actor_(db,r),image=image_(db,b.image_data);Object.assign(actor,{avatar_data:image.data,avatar_type:image.type});return {ok:true};}
  if(path==='preferences'){
    const prior=db.rows('user_preferences').find(p=>p.account_id===user.id);
    if(method==='GET')return prior?.settings||{};
    if(method==='PUT'){const settings=Object.fromEntries(Object.entries(b).filter(([k])=>['layer','markers','information','showIds'].includes(k)));if(JSON.stringify(settings).length>8192)fail_(422,'Слишком большой набор настроек');if(prior)prior.settings=settings;else db.add('user_preferences',{account_id:user.id,settings});return {ok:true};}
  }
  if(path==='admin/test-profiles'&&method==='GET')return db.rows('accounts').filter(a=>a.is_test_profile).map(a=>publicUser_(db,a));
  if(path==='chat/messages'&&method==='GET')return chat_(db,r);
  if(path==='chat/messages'&&method==='POST')return sendChat_(db,r);
  let match=/^chat\/messages\/(\d+)\/reaction$/.exec(path);if(match&&method==='POST')return react_(db,r,Number(match[1]));
  match=/^admin\/chat\/messages\/(\d+)$/.exec(path);if(match&&method==='DELETE')return deleteMessage_(db,Number(match[1]));
  match=/^admin\/chat\/users\/(\d+)\/ban$/.exec(path);if(match&&method==='POST'){const target=db.rows('accounts').find(a=>a.id===Number(match[1]));if(!target)fail_(404,'Пользователь не найден');if(target.role==='admin'||target.id===user.id)fail_(403,'Нельзя ограничить чат администратору');if(typeof b.banned!=='boolean')fail_(422,'Укажите состояние блокировки');target.chat_banned=b.banned;return {ok:true,banned:target.chat_banned};}
  if(path==='admin/provinces/bulk-preview'&&method==='POST')return bulk_(db,b,false);
  if(path==='admin/provinces/bulk-edit'&&method==='POST')return bulk_(db,b,true);
  match=/^admin\/provinces\/(\d+)$/.exec(path);if(match&&method==='PATCH'){const id=Number(match[1]);editProvince_(db,id,b);return provincePayload_(db,id);}
  if(path==='admin/markers'&&method==='POST')return createMarker_(db,b);
  match=/^admin\/markers\/(\d+)$/.exec(path);if(match&&method==='DELETE'){const id=Number(match[1]);if(!db.rows('map_markers').some(m=>m.id===id))fail_(404,'Маркер не найден');db.remove('map_markers',m=>m.id===id);return {id,deleted:true};}
  match=/^provinces\/(\d+)\/name$/.exec(path);if(match&&method==='PATCH'){
    const id=Number(match[1]),state=db.rows('province_values').find(v=>v.province_id===id&&v.layer==='states');
    if(!state||!db.rows('account_states').some(a=>a.account_id===user.id&&a.state_id===state.category_id))fail_(403,'Вы не владеете государством этой провинции');
    const p=db.rows('provinces').find(p=>p.id===id&&p.kind==='land');if(!p)fail_(404,'Провинция не найдена');if(Object.keys(b).some(k=>k!=='name'))fail_(422,'Разрешено менять только название');p.name=normalize_('name',b.name);return {id,name:p.name};
  }
  fail_(404,'Метод API не найден');
}
