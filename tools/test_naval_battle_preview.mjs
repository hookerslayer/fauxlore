import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

for(const file of ['militaryEngine.js','modifierSystem.js'])assert.equal(
  readFileSync(new URL(`../sixiemeterre_northeast/${file}`,import.meta.url),'utf8'),
  readFileSync(new URL(`../supabase/functions/naval-battle-preview/${file}`,import.meta.url),'utf8'),
  `Server copy of ${file} must match the source rules`);

let handler,role='admin',privateReads=0;
globalThis.Deno={serve(callback){handler=callback;},env:{get(key){return key==='SUPABASE_URL'?'https://example.supabase.co':key==='SUPABASE_SERVICE_ROLE_KEY'?'service-test-key':undefined;}}};
const battle={id:7,domain:'naval',status:'pending',participants:[
  {state_id:1,formation_id:10,units:[{unit_id:101,name:'Ладья',quantity:1}],naval_state:[],leader_skills:{}},
  {state_id:2,formation_id:20,units:[{unit_id:101,name:'Ладья',quantity:1}],naval_state:[],leader_skills:{}},
]};
globalThis.fetch=async (url,options)=>{
  if(String(url).endsWith('/naval_battle_source_api')){
    privateReads++;assert.equal(options.headers.apikey,'service-test-key');
    return new Response(JSON.stringify(battle),{status:200,headers:{'Content-Type':'application/json'}});
  }
  assert.equal(JSON.parse(options.body).path,'auth/me');
  return new Response(JSON.stringify({user:{role}}),{status:200,headers:{'Content-Type':'application/json'}});
};
await import('../supabase/functions/naval-battle-preview/index.js');
const call=body=>handler(new Request('https://example.test/naval-battle-preview',{
  method:'POST',headers:{authorization:'Bearer test-jwt',apikey:'sb_publishable_test'},body:JSON.stringify(body),
}));
const settings={attacker_state_id:1,poor_visibility:false,safe:{},adverse:{},withdraw:{},pursue:{}};
const first=await call({battle_id:7,settings});assert.equal(first.status,200);
const preview=await first.json();
assert.equal(preview.battle_id,7);
assert.equal(preview.losses.length,2);
assert.equal(preview.naval_states.length,2);
assert.equal(typeof preview.summary,'string');
const forged=await (await call({battle_id:7,settings,participants:[{state_id:999}],random_seed:'forged'})).json();
assert.deepEqual(forged,preview,'Client-supplied participants and seed must be ignored');
role='player';assert.equal((await call({battle_id:7,settings})).status,403);
assert.equal(privateReads,2,'Non-admin must not read the battle source');
role='admin';assert.equal((await call({battle_id:7,settings:{...settings,attacker_state_id:999}})).status,400);
assert.equal((await handler(new Request('https://example.test/naval-battle-preview',{method:'POST',body:'{}'}))).status,401);
console.log('Naval battle preview: admin-only read, deterministic result and forged inputs passed');
