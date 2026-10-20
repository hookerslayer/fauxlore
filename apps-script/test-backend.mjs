// Exercises the real Apps Script handlers with a disposable in-memory Sheets service.
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
const root=new URL('../',import.meta.url),exportPath=new URL('.local/google-migration/export.json',root);
if(!fs.existsSync(exportPath))throw new Error('Run tools/export_google_data.py first; the exported private fixture stays in .local.');
const fixture=JSON.parse(fs.readFileSync(exportPath,'utf8'));
let tables=new Map(Object.entries(fixture.sheets).map(([name,t],id)=>[name,{id,headers:t.headers,data:structuredClone(t.rows),maxRows:t.rows.length+1}])),failNext=false,batches=0;
const props=new Map([['DATABASE_SPREADSHEET_ID','test'],['SITE_URL','http://127.0.0.1:8003']]),cache=new Map();
const context=vm.createContext({console,PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k)||null,setProperty:(k,v)=>props.set(k,v)})},
  SpreadsheetApp:{openById:()=>({getSheetByName:name=>{const t=tables.get(name);return t&&{getDataRange:()=>({getValues:()=>[structuredClone(t.headers),...structuredClone(t.data)]}),getLastRow:()=>t.data.length+1,getMaxRows:()=>t.maxRows,getSheetId:()=>t.id};}})},
  Sheets:{Spreadsheets:{batchUpdate:({requests})=>{if(failNext){failNext=false;throw new Error('Injected atomic failure');}const next=structuredClone(tables);for(const req of requests){if(req.appendDimension){const t=[...next.values()].find(t=>t.id===req.appendDimension.sheetId);t.maxRows+=req.appendDimension.length;continue;}const u=req.updateCells,t=[...next.values()].find(t=>t.id===u.range.sheetId);u.rows.forEach((r,i)=>{t.data[u.range.startRowIndex+i-1]=r.values.map(c=>c.userEnteredValue?Object.values(c.userEnteredValue)[0]:null);});}for(const [name,t] of next)Object.assign(tables.get(name),t);batches++;}}},
  LockService:{getScriptLock:()=>({tryLock:()=>true,releaseLock:()=>{}})},
  CacheService:{getScriptCache:()=>({get:k=>cache.get(k)||null,put:(k,v)=>cache.set(k,v),remove:k=>cache.delete(k)})},
  ScriptApp:{getService:()=>({getUrl:()=> 'https://script.google.com/macros/s/test/exec'})},
  Utilities:{DigestAlgorithm:{SHA_256:'sha256'},Charset:{UTF_8:'utf8'},getUuid:()=>crypto.randomUUID(),computeDigest:(alg,value)=>[...crypto.createHash('sha256').update(typeof value==='string'?value:Buffer.from(value.map(b=>b&255))).digest()],base64Decode:value=>[...Buffer.from(value,'base64')],base64Encode:value=>Buffer.from(typeof value==='string'?value:value.map(b=>b&255)).toString('base64'),newBlob:bytes=>({getDataAsString:()=>Buffer.from(bytes.map(b=>b&255)).toString('utf8')})}
});
for(const name of ['Store.gs','Auth.gs','Map.gs','Chat.gs','Code.gs','Setup.gs'])vm.runInContext(fs.readFileSync(new URL('apps-script/'+name,root),'utf8'),context,{filename:name});
const rows=name=>tables.get(name).data.filter(r=>r[0]!=null&&r[0]!=='').map(r=>Object.fromEntries(tables.get(name).headers.map((h,i)=>[h,r[i]??null])));
const admin=rows('accounts').find(a=>a.role==='admin'),player=rows('accounts').find(a=>a.role==='player');assert.ok(admin&&player);
const adminToken='a'.repeat(64),playerToken='b'.repeat(64),sha=s=>crypto.createHash('sha256').update(s).digest('hex');
tables.get('sessions').data.push([sha(adminToken),admin.id,'2099-01-01T00:00:00Z'],[sha(playerToken),player.id,'2099-01-01T00:00:00Z']);
const call=(path,method='GET',body={},token=null,extra={})=>context.fxRpc({path,method,body,token,origin:'http://127.0.0.1:8003',request_id:crypto.randomUUID(),...extra});
const ok=result=>{assert.equal(result.ok,true,result.error);return result.data;};
props.set('GOOGLE_CLIENT_ID','test-client');props.set('GOOGLE_CLIENT_SECRET','test-secret');
props.set('SITE_URLS',JSON.stringify(['http://127.0.0.1:8003','https://hookerslayer.github.io/fauxlore']));
for(const site of ['http://127.0.0.1:8003','https://hookerslayer.github.io/fauxlore']){
  const origin=new URL(site).origin,start=ok(call('auth/start','POST',{origin,site,challenge:sha('proof')},null,{origin}));
  assert.equal(JSON.parse(cache.get('oauth:'+start.state)).site,site);
  assert.equal(new URL(start.url).searchParams.get('redirect_uri'),'https://script.google.com/macros/s/test/exec');
  ok(call('health','GET',{},null,{origin}));
}
assert.equal(call('health','GET',{},null,{origin:'https://evil.example'}).status,403);
assert.equal(call('auth/start','POST',{origin:'http://127.0.0.1:8003',site:'https://hookerslayer.github.io/fauxlore',challenge:sha('proof')}).status,400);
assert.equal(call('auth/start','POST',{origin:'https://hookerslayer.github.io',site:'https://hookerslayer.github.io/other-project',challenge:sha('proof')},null,{origin:'https://hookerslayer.github.io'}).status,400);
assert.equal(call('auth/start','POST',{origin:'https://hookerslayer.github.io',site:'https://hookerslayer.github.io/fauxlore/../other',challenge:sha('proof')},null,{origin:'https://hookerslayer.github.io'}).status,400);
const map=ok(call('map'));assert.equal(map.provinces.length,fixture.source_counts.provinces);assert.equal(map.markers.length,rows('map_markers').filter(m=>['capital','city','fortress','port'].includes(m.type)).length);assert.ok(!JSON.stringify(map).includes('password_hash'));
assert.equal(call('admin/test-profiles').status,401);assert.equal(call('admin/test-profiles','GET',{},playerToken).status,403);
assert.equal(call('admin/provinces/1','PATCH',{role:'admin'},playerToken).status,403);
const bounds=map.region,p=map.provinces.find(p=>p.kind==='land'&&p.center[0]>=bounds[0]&&p.center[0]<bounds[2]&&p.center[1]>=bounds[1]&&p.center[1]<bounds[3]);assert.ok(p);
const changed=ok(call('admin/provinces/'+p.id,'PATCH',{terrain_type:'forest',courts:123,state:'Integration State'},adminToken));assert.equal(changed.population,492);assert.equal(changed.terrain_type,'forest');assert.equal(changed.layers.states.name,'Integration State');
assert.equal(call('admin/provinces/'+p.id,'PATCH',{role:'admin'},adminToken).status,422);
assert.equal(call('admin/provinces/'+p.id,'PATCH',{terrain_type:'desert'},adminToken).status,422);
assert.equal(call('admin/provinces/'+p.id,'PATCH',{courts:-1},adminToken).status,422);
const before=rows('map_markers').length,id=crypto.randomUUID(),body={province_id:p.id,x:p.center[0],y:p.center[1],type:'port',name:'Test port'};
const marker=ok(call('admin/markers','POST',body,adminToken,{request_id:id}));assert.equal(marker.state_name,'Integration State');ok(call('admin/markers','POST',body,adminToken,{request_id:id}));assert.equal(rows('map_markers').length,before+1);
assert.equal(call('admin/markers','POST',{...body,name:'Different'},adminToken,{request_id:id}).status,409);
const snapshot=JSON.stringify([...tables]);failNext=true;assert.equal(call('admin/provinces/'+p.id,'PATCH',{name:'Must roll back'},adminToken).status,500);assert.equal(JSON.stringify([...tables]),snapshot);
const categoryCount=rows('map_categories').length;
const rule={condition_field:'courts',condition_value:123,target_field:'state',target_value:'Preview State'};
const preview=ok(call('admin/provinces/bulk-preview','POST',{rules:[rule]},adminToken));assert.ok(preview.total>=1);assert.equal(rows('map_categories').length,categoryCount);
assert.equal(call('admin/provinces/bulk-edit','POST',{rules:[rule,{...rule,target_value:'Conflict'}]},adminToken).status,409);
const bulk=ok(call('admin/provinces/bulk-edit','POST',{rules:[{...rule,target_field:'terrain_type',target_value:'marsh'}]},adminToken));assert.equal(bulk.updated_count,preview.total);
ok(call('preferences','PUT',{layer:'races',role:'admin'},playerToken));assert.equal(ok(call('preferences','GET',{},playerToken)).role,undefined);
const msg=ok(call('chat/messages','POST',{text:'Test message'},playerToken));assert.equal(ok(call('chat/messages/'+msg.id+'/reaction','POST',{reaction:'like'},adminToken)).reputation_delta,1);
assert.equal(ok(call('chat/messages/'+msg.id+'/reaction','POST',{reaction:'like'},adminToken)).reputation_delta,-1);
const chat=ok(call('chat/messages','GET',{},adminToken));assert.ok(chat.messages.some(m=>m.id===msg.id));assert.ok(!JSON.stringify(chat).includes('password_hash'));
ok(call('admin/chat/messages/'+msg.id,'DELETE',{},adminToken));assert.ok(ok(call('chat/messages','GET',{},adminToken)).messages.find(m=>m.id===msg.id).deleted);
const db=vm.runInContext('new Store_()',context);
for(const blob of rows('_blobs')){const encoded=db.blob('@blob:'+blob.key);assert.equal(crypto.createHash('sha256').update(Buffer.from(encoded,'base64')).digest('hex'),blob.sha256);}
const ticket='c'.repeat(64),verifier='d'.repeat(64);cache.set('ticket:'+ticket,JSON.stringify({identity:{sub:'integration-google-sub',email:'new-integration-account@gmail.com',email_verified:true,name:'Google player'},challenge:sha(verifier),site:'http://127.0.0.1:8003'}));
assert.equal(call('auth/complete','POST',{ticket,verifier},null,{origin:'https://hookerslayer.github.io'}).status,401);
assert.equal(call('auth/complete','POST',{ticket,verifier:'e'.repeat(64)}).status,401);
const login=ok(call('auth/complete','POST',{ticket,verifier}));assert.equal(login.user.role,'player');assert.equal(ok(call('auth/me','GET',{},login.token)).user.id,login.user.id);assert.equal(call('auth/complete','POST',{ticket,verifier}).status,401);
ok(call('auth/logout','POST',{},login.token));assert.equal(ok(call('auth/me','GET',{},login.token)).user,null);
console.log(JSON.stringify({passed:true,source_provinces:map.provinces.length,source_markers:map.markers.length,atomic_batches:batches,verified:'permissions, validation, migration blobs, idempotency, atomic failure, bulk rules, chat, Google session lifecycle'}));
