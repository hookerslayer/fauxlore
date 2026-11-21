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

// Журнал последнего расчётного хода: договор и торговая зона поставляют зерно,
// лес вывозится в чужую зону.
const journal=[
  {resource_name:'Зерно',production:600,consumption:1000,contract_import:120,contract_export:0,zone_import:380,zone_export:0},
  {resource_name:'Лес',production:900,consumption:200,contract_import:0,contract_export:50,zone_import:0,zone_export:150},
];

{
  const forecast=calculateInternalTradeForecast(production,15,new Map(),journal);
  const grain=forecast.resources.find(row=>row.resource_name==='Зерно');
  const forest=forecast.resources.find(row=>row.resource_name==='Лес');
  assert.equal(grain.production,600,'местное производство остаётся отдельной величиной');
  assert.equal(grain.contract_import,120);
  assert.equal(grain.zone_import,380);
  assert.equal(grain.received,500);
  assert.equal(grain.balance,100,'баланс учитывает поставки договора и зоны');
  assert.equal(forest.contract_export,50);
  assert.equal(forest.zone_export,150);
  assert.equal(forest.delivered,200);
  assert.equal(forest.balance,500,'экспорт уменьшает баланс');
}

{
  const forecast=calculateInternalTradeForecast(production,15,new Map());
  const grain=forecast.resources.find(row=>row.resource_name==='Зерно');
  assert.equal(grain.contract_import,0,'без журнала поставок нет');
  assert.equal(grain.zone_import,0);
  assert.equal(grain.balance,-400,'базовый баланс не меняется');
}

{
  const forecast=calculateInternalTradeForecast(production,15,new Map(),[{resource_name:'Лес',zone_import:9999}]);
  const forest=forecast.resources.find(row=>row.resource_name==='Лес');
  assert.equal(forest.zone_import,9999);
  assert.equal(forest.balance,10699);
}

{
  // Экспорт больше доступного излишка: вывезти можно только 700, баланс 0,
  // а не отрицательный «дефицит» из-за старых поставок.
  const forecast=calculateInternalTradeForecast(production,15,new Map(),[{resource_name:'Лес',zone_export:1000}]);
  const forest=forecast.resources.find(row=>row.resource_name==='Лес');
  assert.equal(forest.delivered,700,'экспорт ограничен излишком после потребления');
  assert.equal(forest.balance,0,'экспорт не создаёт ложный дефицит');
}

{
  // Если потребление больше производства, экспортировать нечего,
  // и баланс остаётся настоящим дефицитом.
  const deficitProduction=[{resource:'Лес',category:'Повседневные товары',population:1000,production:100,consumption:1000,balance:-900}];
  const forecast=calculateInternalTradeForecast(deficitProduction,15,new Map(),[{resource_name:'Лес',zone_export:200}]);
  const forest=forecast.resources.find(row=>row.resource_name==='Лес');
  assert.equal(forest.delivered,0);
  assert.equal(forest.balance,-900,'дефицит сохраняется');
}

setEconomyConfig(previous);
console.log('Resource balance projection: local production, contract and zone flows: OK');
