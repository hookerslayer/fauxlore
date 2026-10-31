import assert from 'node:assert/strict';

let handler;
globalThis.Deno={serve(callback){handler=callback;},env:{get(key){return key==='SUPABASE_URL'?'https://example.supabase.co':key==='SUPABASE_SERVICE_ROLE_KEY'?'service-test-key':undefined;}}};
const province={id:42,kind:'land',province_type:'Регион',population:1000,development:100,control:100,
  trade_status:'Отсутствует',layers:{states:{id:5,name:'Тест',crime:0,corruption:0,
    estate_tax_rates:{Знать:10,Духовенство:1,Горожане:3,Крестьяне:1}},
    races:{id:1,name:'Люди'},religions:{id:1,name:'Правоверие'},resources:{name:'Зерно'}}};
let map={data_revision:7,live_revision:9,provinces:[province]};
let role='admin';
let privateReads=0, mapReads=0;
globalThis.fetch=async (_url,options)=>{
  if(String(_url).endsWith('/military_api'))return new Response(JSON.stringify({upkeep_breakdown:{army:60,garrison_by_estate:{Знать:40}}}),{status:200,headers:{'Content-Type':'application/json'}});
  if(String(_url).endsWith('/garrison_api'))return new Response(JSON.stringify({provinces:[{sponsor:'Знать',units:[{quantity:100,upkeep:1}],fort_level:0,wall_level:0}]}),{status:200,headers:{'Content-Type':'application/json'}});
  if(String(_url).endsWith('/colonization_api'))return new Response(JSON.stringify({missions:[{id:1}]}),{status:200,headers:{'Content-Type':'application/json'}});
  if(String(_url).endsWith('/projection_source_api')){
    privateReads++;
    assert.equal(options.headers.apikey,'service-test-key');
    const sharedZone={id:1,name:'Тестовая зона'};
    const own={...province,layers:{...province.layers,trade:sharedZone}};
    const foreign={...province,id:43,layers:{...province.layers,states:{id:6,name:'Чужое государство'},trade:sharedZone}};
    return new Response(JSON.stringify({...map,provinces:[own,foreign]}),{status:200,headers:{'Content-Type':'application/json'}});
  }
  const path=JSON.parse(options.body).path;
  if(path==='map')mapReads++;
  const data=path==='map'?map:path==='auth/me'?{user:{role}}:
    path==='admin/states'||path==='my/states'?[{id:5,name:'Тест',principles:{}}]:
    path==='admin/states/5/indicators'||path==='my/states/5/indicators'?{permanent_modifiers:[],corruption:0}:
    path==='admin/states/5/politics'||path==='my/states/5/politics'?[]:
    path==='admin/states/5/trade-overview'||path==='my/states/5/trade-overview'?{resources:[],zones:[]}:
    path==='admin/states/5/estate-tax-rates'||path==='my/states/5/estate-tax-rates'?{groups:[{estate:'Знать',rate:10},{estate:'Духовенство',rate:1},{estate:'Горожане',rate:3},{estate:'Крестьяне',rate:1}]}:
    path==='admin/states/5/tax-rates'||path==='my/states/5/tax-rates'?{buckets:{Корона:1000},prestige:10,army_upkeep_forecast:100}:
    path==='my/trade-agreements'?{agreements:[{status:'accepted',from_state_id:5,to_state_id:6,terms:{from_gold:100,to_gold:20}}]}:
    path==='admin/states/5/trade-duty'||path==='my/states/5/trade-duty'?{rate:15}:null;
  assert.notEqual(data,null,`Unexpected RPC ${path}`);
  return new Response(JSON.stringify(data),{status:200,headers:{'Content-Type':'application/json'}});
};
await import('../supabase/functions/province-projection/index.js');
const {calculateStatePolitics}=await import('../supabase/functions/province-projection/economy.js');
const estateNames=['Знать','Духовенство','Горожане','Крестьяне'];
const politicsFor=statuses=>calculateStatePolitics([province],estateNames.map((name,i)=>({group_type:'estate',group_key:name,status:statuses[i],loyalty:.5})),'Тест',{permanent_modifiers:[],corruption:0});
const capped=politicsFor(['Ключевое','Значимое','Бесправное','Бесправное']);
const near=(actual,expected)=>assert.ok(Math.abs(actual-expected)<1e-10,`${actual} != ${expected}`);
near(capped.estateInfluence['Горожане']+capped.estateInfluence['Крестьяне'],.1);
near(Object.values(capped.estateInfluence).reduce((a,b)=>a+b,0),1);
near(capped.estateModifierBreakdown['Знать'].ambition,.4);
near(capped.estateModifierBreakdown['Духовенство'].ambition,.2);
near(capped.estateModifierBreakdown['Крестьяне'].ambition,0);
near(capped.estateLoyalty['Крестьяне'],.5+capped.estateInfluence['Крестьяне']);
const onlyPowerless=politicsFor(estateNames.map(()=>'Бесправное'));
near(Object.values(onlyPowerless.estateInfluence).reduce((a,b)=>a+b,0),1);
const noPowerless=politicsFor(estateNames.map(()=>'Ключевое'));
near(Object.values(noPowerless.estateInfluence).reduce((a,b)=>a+b,0),1);
const belowCap=politicsFor(['Бесправное','Ключевое','Ключевое','Ключевое']);
assert.ok(belowCap.estateInfluence['Знать']<.1);
near(belowCap.estateInfluence['Знать'],belowCap.estateWeights['Знать']/Object.values(belowCap.estateWeights).reduce((a,b)=>a+b,0));
const call=body=>handler(new Request('https://example.test/province-projection',{
  method:'POST',headers:{authorization:'Bearer test-jwt',apikey:'sb_publishable_test'},body:JSON.stringify(body),
}));

const first=await call({province_id:42});
assert.equal(first.status,200);
const result=await first.json();
assert.equal(result.province_id,42);
assert.equal(result.data_revision,7);
assert.equal(result.live_revision,9);
assert.equal(typeof result.taxes,'number');
const forged=await (await call({province_id:42,population:999999999,estate_tax_rates:{Знать:999999}})).json();
assert.deepEqual(forged,result,'Client-supplied economic inputs must be ignored');
const state=await (await call({state_id:5})).json();
assert.equal(state.provinces.length,1);
assert.equal(state.provinces[0].id,42);
assert.equal(typeof state.provinces[0].taxes,'number');
assert.equal(state.production_rows.some(row=>row.resource==='Зерно'),true);
const politics=await (await call({state_id:5,view:'politics'})).json();
assert.equal(typeof politics.derived.estateInfluence['Крестьяне'],'number');
assert.equal(typeof politics.derived.estatePopulations['Крестьяне'],'number');
assert.equal(typeof politics.system_effects.crimeTaxMultiplier,'number');
const mapReadsBeforeTrade=mapReads;
const trade=await (await call({state_id:5,view:'trade'})).json();
assert.equal(Array.isArray(trade.resources),true);
assert.equal(Array.isArray(trade.zones),true);
assert.equal(typeof trade.tax_forecast.buckets['Корона'],'number');
assert.equal(typeof trade.adjusted_internal_income,'number');
assert.equal(typeof trade.market_income,'number');
assert.equal(typeof trade.zone_income_by_estate['Корона'],'number');
const finance=await (await call({state_id:5,view:'finance'})).json();
assert.equal(finance.finance.treasury_expense_rows[0][1],60);
assert.equal(finance.finance.treasury_expense_rows[1][1],1000);
assert.equal(finance.finance.trade_gold_in,20);
assert.equal(finance.finance.trade_gold_out,100);
assert.equal(finance.finance.sponsor_garrison['Знать'],40);
assert.equal(finance.finance.current_treasury,1000);
assert.equal(trade.zones.length,1);
assert.equal(trade.zones[0].participants.find(p=>p.state_id===6).local_income,null);
assert.equal(typeof trade.zones[0].participants.find(p=>p.state_id===5).local_income,'number');
assert.equal(privateReads,2);
assert.equal(mapReads,mapReadsBeforeTrade,'Trade and finance must not request the unused public map');
assert.equal((await call({state_id:6})).status,403);
assert.equal((await call({state_id:6,view:'trade'})).status,403);
assert.equal(privateReads,2,'Forbidden state must not access the private map');
role='player';
assert.equal((await call({state_id:5})).status,200);
map={data_revision:7,live_revision:9,provinces:[{...province,layers:{...province.layers,states:{id:5,name:'Тест'}}}]};
assert.equal((await call({province_id:42})).status,403);
assert.equal((await call({province_id:43})).status,404);
assert.equal((await handler(new Request('https://example.test/province-projection',{method:'POST',body:'{}'}))).status,401);
console.log('Province projection: authorized read, forbidden read, unknown province and forged inputs passed');
