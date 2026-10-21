import assert from 'node:assert/strict';
import {calculateProvinceEconomy,calculateProvinceValue,calculateStateProduction,buildTurnEconomyReport} from '../economy.js';

const province=(overrides={})=>({kind:'land',province_type:'Столичная',population:10000,belonging:'Корона',trade_status:'Центр торговли I',layers:{races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}},...overrides});
const capital=calculateProvinceEconomy(province());
assert.equal(capital.taxes,400);
assert.equal(capital.production,8000);
assert.equal(capital.tradeInfluence,28.13);
assert.equal(capital.populationGrowth,180);
assert.equal(calculateProvinceValue(province()),54);
const city=calculateProvinceEconomy(province({province_type:'Городская',population:3000,layers:{races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Соль'}},trade_status:'Устье реки'}));
assert.equal(city.taxes,90);
assert.equal(city.production,735);
assert.equal(city.tradeInfluence,11);
assert.equal(calculateProvinceEconomy(province({province_type:'Регион',population:2500})).taxes,40);
assert.equal(calculateProvinceEconomy(province({province_type:'Территориальная',population:2500})).taxes,0);
assert.equal(calculateProvinceEconomy(province({control:50})).taxes,200);
assert.equal(calculateProvinceEconomy(province({control:50})).production,4000);
assert.equal(calculateProvinceEconomy(province({control:0})).taxes,0);
assert.equal(calculateProvinceEconomy(province({layers:{states:{id:1,crime:.2},races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}}})).production,6400);
assert.equal(calculateProvinceEconomy(province({layers:{states:{id:1,crime:1},races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}}})).production,0);
const totals=calculateStateProduction([province(),province({population:3000,province_type:'Городская'})]);
const grain=totals.find(item=>item.resource==='Зерно');
assert.equal(grain.production,9680);
assert.equal(grain.consumption,650);
assert.equal(grain.balance,9030);
assert.equal(totals.some(item=>item.resource==='Эфемерная пустошь'||item.resource==='Магическая пустошь'),false);
const turnReport=buildTurnEconomyReport([
  province({layers:{states:{id:1,name:'Микельский Союз'},races:{name:'Люди'},religions:{name:'Атомизм'},resources:{name:'Красители'}},province_type:'Регион',population:3735}),
  province({layers:{states:{id:1,name:'Микельский Союз'},races:{name:'Люди'},religions:{name:'Астроизм'},resources:{name:'Зерно'}},province_type:'Регион',population:4278}),
]);
assert.equal(turnReport.length,1);
assert.equal(turnReport[0].province_count,2);
assert.equal(turnReport[0].gross_taxes,128.21);
assert.equal(turnReport[0].production.find(item=>item.resource==='Зерно').produced,3286);
assert.equal(turnReport[0].crime,.2);
console.log('Economy calculations: 24 assertions passed');
