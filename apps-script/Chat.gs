function image_(db,value){
  if(value==null)return {data:null,type:null};
  if(typeof value!=='string'||value.length>2800000)fail_(413,'Изображение должно быть не больше 2 МБ');
  const match=/^data:(image\/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+/=]+)$/.exec(value);if(!match)fail_(422,'Поддерживаются PNG, JPEG, GIF и WebP');
  let bytes;try{bytes=Utilities.base64Decode(match[2]);}catch(e){fail_(422,'Некорректное изображение');}
  if(!bytes.length||bytes.length>2097152)fail_(413,'Изображение должно быть не больше 2 МБ');
  const b=bytes.map(x=>x&255),signature=match[1]==='image/png'?[137,80,78,71,13,10,26,10]:match[1]==='image/jpeg'?[255,216,255]:match[1]==='image/gif'?[71,73,70]:[82,73,70,70];
  if(!signature.every((v,i)=>b[i]===v)||(match[1]==='image/webp'&&![87,69,66,80].every((v,i)=>b[i+8]===v)))fail_(422,'Содержимое файла не совпадает с форматом');
  return {data:db.putBlob(match[2]),type:match[1]};
}
function card_(db,user){const p=publicUser_(db,user);return Object.fromEntries(['id','nickname','role','reputation','avatar_url','is_test_profile'].map(k=>[k,p[k]]));}
function chat_(db,request){
  const actual=require_(db,request,false),actor=actor_(db,request),accounts=new Map(db.rows('accounts').map(a=>[a.id,a])),cards=new Map();
  const reactions=db.rows('chat_reactions');
  const messages=db.rows('chat_messages').slice().sort((a,b)=>b.id-a.id).slice(0,100).reverse().map(m=>{
    const author=accounts.get(m.account_id);if(!cards.has(author.id))cards.set(author.id,card_(db,author));
    const mine=reactions.find(r=>r.message_id===m.id&&r.account_id===actor.id),counts={};
    for(const row of reactions.filter(r=>r.message_id===m.id))counts[row.reaction]=(counts[row.reaction]||0)+1;
    return {id:m.id,text:m.deleted_at?'Сообщение удалено администратором':m.body,image_url:!m.deleted_at&&m.image_data?'data:'+m.image_type+';base64,'+db.blob(m.image_data):null,created_at:m.created_at,deleted:!!m.deleted_at,author:cards.get(author.id),reactions:counts,my_reaction:mine?.reaction||null,can_delete:actual.role==='admin'&&!m.deleted_at,can_mute:actual.role==='admin'&&author.role!=='admin'&&!author.chat_banned,author_banned:author.chat_banned};
  });
  return {messages,current_user:card_(db,actor),can_moderate:actual.role==='admin',muted:actor.chat_banned};
}
function sendChat_(db,request){
  const actor=actor_(db,request),body=request.body;if(actor.chat_banned)fail_(403,'Этому профилю запрещено писать в чат');
  const text=text_(body.text,2000,true),image=image_(db,body.image_data);
  if(body.image_selected&&!image.data)fail_(422,'Изображение не было передано');if(!text&&!image.data)fail_(422,'Добавьте текст или изображение');
  const id=db.nextId('chat_messages');db.add('chat_messages',{id,account_id:actor.id,body:text,image_data:image.data,image_type:image.type,created_at:now_(),deleted_at:null});return {id,image_attached:!!image.data};
}
function react_(db,request,id){
  const actor=actor_(db,request),reaction=request.body.reaction;if(!['like','dislike','laugh'].includes(reaction))fail_(422,'Неизвестная реакция');
  const message=db.rows('chat_messages').find(r=>r.id===id&&!r.deleted_at);if(!message)fail_(404,'Сообщение не найдено');
  const previous=db.rows('chat_reactions').find(r=>r.message_id===id&&r.account_id===actor.id),next=previous?.reaction===reaction?null:reaction,impact={like:1,dislike:-1,laugh:0},delta=(impact[next]||0)-(impact[previous?.reaction]||0);
  db.remove('chat_reactions',r=>r.message_id===id&&r.account_id===actor.id);if(next)db.add('chat_reactions',{message_id:id,account_id:actor.id,reaction:next});
  const reputation_delta=actor.id===message.account_id?0:delta;
  db.rows('accounts').find(r=>r.id===message.account_id).reputation+=reputation_delta;return {reaction:next,reputation_delta};
}
function deleteMessage_(db,id){
  const message=db.rows('chat_messages').find(r=>r.id===id&&!r.deleted_at);if(!message)fail_(404,'Сообщение не найдено');
  const impact={like:1,dislike:-1,laugh:0},delta=db.rows('chat_reactions').filter(r=>r.message_id===id&&r.account_id!==message.account_id).reduce((sum,r)=>sum+(impact[r.reaction]||0),0);
  db.rows('accounts').find(r=>r.id===message.account_id).reputation-=delta;db.remove('chat_reactions',r=>r.message_id===id);
  Object.assign(message,{body:null,image_data:null,image_type:null,deleted_at:now_()});return {ok:true};
}
