import assert from 'node:assert/strict';
import {calculateInternalTradeForecast,setEconomyConfig,getEconomyConfig} from '../supabase/functions/province-projection/economy.js';

const previous=getEconomyConfig();
setEconomyConfig({
  resources:[
    {name:'Зерно',category:'Повседневные товары',value:1,production:.5,consumption:1,showInProduction:true},
    {name:'Лес',category:'Повседневные товары',value:1,production:.4,consumption:.2,showInProduction:true},
  ],
});

const production=[
  {resource:'Зерно',category:'Повседневные товары',population:10000,production:600,consumption:1000,balance:-400},
  {resource:'Лес',category:'Повседневные товары',population:10000,production:900,consumption:200,balance:700},
];

// Договор: государство 2 получает зерно 120 и отдаёт лес 50.
const agreements=[{status:'accepted',from_state_id:6,to_state_id:2,
  terms:{from_goods:[{name:'Зерно',quantity:120}],to_goods:[{name:'Лес',quantity:50}]}}];

{
  const forecast=calculateInternalTradeForecast(production,15,new Map(),{agreements,zones:[],stateId:2});
  const grain=forecast.resources.find(row=>row.resource_name==='Зерно');
  const forest=forecast.resources.find(row=>row.resource_name==='Лес');
  assert.equal(grain.contract_import,120,'ввоз берётся из условий договора');
  assert.equal(grain.balance,-280,'дефицит уменьшается на ввоз');
  assert.equal(forest.contract_export,50,'вывоз берётся из условий договора');
  assert.equal(forest.balance,650,'излишек уменьшается на вывоз');
}

{
  // Журнал прошлого хода больше не участвует в прогнозе.
  const forecast=calculateInternalTradeForecast(production,15,new Map(),{agreements:[],zones:[],stateId:2,actualFlows:[{resource_name:'Зерно',contract_import:999}]});
  const grain=forecast.resources.find(row=>row.resource_name==='Зерно');
  assert.equal(grain.contract_import,0);
  assert.equal(grain.balance,-400);
}

{
  // Вывезти больше излишка нельзя.
  const big=[{status:'accepted',from_state_id:2,to_state_id:6,terms:{from_goods:[{name:'Лес',quantity:1000}],to_goods:[]}}];
  const forecast=calculateInternalTradeForecast(production,15,new Map(),{agreements:big,zones:[],stateId:2});
  const forest=forecast.resources.find(row=>row.resource_name==='Лес');
  assert.equal(forest.contract_export,700,'экспорт ограничен излишком');
  assert.equal(forest.balance,0);
}

{
  // Зона покрывает половину дефицита.
  const zones=[{id:1,resources:[{resource_name:'Зерно',local_supply:1000,demand:2000}]}];
  const forecast=calculateInternalTradeForecast(production,15,new Map(),{agreements:[],zones,stateId:2});
  const grain=forecast.resources.find(row=>row.resource_name==='Зерно');
  assert.equal(grain.zone_import,200,'ввоз из зоны оценён по покрытию');
  assert.equal(grain.balance,-200,'непокрытый дефицит сохраняется');
}

{
  // Зона принимает только часть излишка.
  const zones=[{id:1,resources:[{resource_name:'Лес',local_supply:2000,demand:500}]}];
  const forecast=calculateInternalTradeForecast(production,15,new Map(),{agreements:[],zones,stateId:2});
  const forest=forecast.resources.find(row=>row.resource_name==='Лес');
  assert.equal(forest.zone_export,175,'вывоз в зону ограничен её спросом');
  assert.equal(forest.balance,525,'непроданный излишек остаётся');
}

setEconomyConfig(previous);
console.log('Next-turn trade forecast: contracts, surplus cap, zone coverage: OK');
