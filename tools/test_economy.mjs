import assert from 'node:assert/strict';
import {calculateProvinceEconomy,calculateProvinceValue,calculateProvinceShare,calculateStateProduction,calculateStatePolitics,DEFAULT_ECONOMY_CONFIG,setEconomyConfig} from '../economy.js';

const province=(overrides={})=>({kind:'land',province_type:'Столичная',population:10000,belonging:'Корона',trade_status:'Центр торговли I',layers:{races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}},...overrides});
const capital=calculateProvinceEconomy(province());
assert.equal(capital.taxes,400);
assert.equal(capital.production,8000);
assert.equal(capital.tradeInfluence,28.13);
assert.equal(capital.populationGrowth,180);
assert.equal(capital.recruitGrowth,15);
assert.equal(capital.recruitLimit,225);
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
const stateRateProvince=province({province_type:'Регион',population:2500,layers:{states:{id:1,name:'Альфа',race_tax_rates:{Зверолюди:.2},religion_tax_rates:{Жизнелизм:.3}},races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}}});
assert.equal(calculateProvinceEconomy(stateRateProvince,'Альфа').taxes,100);
const occupiedRateProvince=province({province_type:'Регион',population:2500,occupation:'Бета',layers:{states:{id:1,name:'Альфа',race_tax_rates:{Люди:.1},religion_tax_rates:{Атомизм:.1}},races:{name:'Люди'},religions:{name:'Атомизм'},resources:{name:'Зерно'}},occupation_race_tax_rates:{Люди:.4},occupation_religion_tax_rates:{Атомизм:.5}});
assert.equal(calculateProvinceEconomy(occupiedRateProvince,'Бета').taxes,90);
const regionalRecruitment=calculateProvinceEconomy(province({province_type:'Регион',population:2500,belonging:'Крестьяне'}));
assert.equal(regionalRecruitment.recruitGrowth,1);
assert.equal(regionalRecruitment.recruitLimit,1);
assert.equal(calculateProvinceEconomy(province({belonging:'Отсутствует'})).recruitLimit,0);
setEconomyConfig({...DEFAULT_ECONOMY_CONFIG,provinceModifiers:{...DEFAULT_ECONOMY_CONFIG.provinceModifiers,Регион:{...DEFAULT_ECONOMY_CONFIG.provinceModifiers.Регион,trade:900}}});
assert.equal(calculateProvinceEconomy(province({province_type:'Регион',population:2500,belonging:'Крестьяне'})).tradeInfluence,2250);
assert.equal(calculateProvinceEconomy(province({province_type:'Регион',population:2500,belonging:'Крестьяне'})).recruitGrowth,1);
assert.equal(calculateProvinceEconomy(province({province_type:'Регион',population:2500,belonging:'Крестьяне'})).recruitLimit,1);
setEconomyConfig(DEFAULT_ECONOMY_CONFIG);
assert.equal(calculateProvinceEconomy(province({layers:{states:{id:1,crime:.2},races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}}})).production,6400);
assert.equal(calculateProvinceEconomy(province({layers:{states:{id:1,crime:1},races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}}})).production,0);
const totals=calculateStateProduction([province(),province({population:3000,province_type:'Городская'})]);
const grain=totals.find(item=>item.resource==='Зерно');
assert.equal(grain.production,9680);
assert.equal(grain.consumption,650);
assert.equal(grain.balance,9030);
assert.equal(totals.some(item=>item.resource==='Эфемерная пустошь'||item.resource==='Магическая пустошь'),false);
const occupied=province({province_type:'Регион',population:10000,trade_status:'Отсутствует',occupation:'Бета',layers:{states:{id:1,name:'Альфа',crime:.2},races:{name:'Люди'},religions:{name:'Астроизм'},resources:{name:'Зерно'}}});
const ownerEconomy=calculateProvinceEconomy(occupied,'Альфа');
const occupierEconomy=calculateProvinceEconomy(occupied,'Бета');
assert.equal(calculateProvinceShare(occupied,'Альфа'),0);
assert.equal(calculateProvinceShare(occupied,'Бета'),.5);
assert.equal(ownerEconomy.taxes,0);
assert.equal(ownerEconomy.production,0);
assert.equal(ownerEconomy.tradeInfluence,0);
assert.equal(calculateProvinceValue(occupied,'Альфа'),0);
assert.equal(occupierEconomy.taxes,80);
assert.equal(occupierEconomy.production,3840);
assert.equal(occupierEconomy.tradeInfluence,.5);
assert.equal(occupierEconomy.populationGrowth,0);
assert.equal(ownerEconomy.recruitGrowth,0);
assert.equal(ownerEconomy.recruitLimit,0);
assert.equal(occupierEconomy.recruitGrowth,3);
assert.equal(occupierEconomy.recruitLimit,38);
const fullValue=calculateProvinceValue({...occupied,occupation:null},'Альфа');
assert.equal(calculateProvinceValue(occupied,'Бета'),Math.round(fullValue*.5));
const politicsProvince=(belonging)=>province({population:10000,belonging,trade_status:'Отсутствует',layers:{states:{id:1,name:'Альфа',crime:.2},races:{id:1,name:'Люди'},religions:{id:2,name:'Атомизм'},resources:{name:'Зерно'}}});
setEconomyConfig({...DEFAULT_ECONOMY_CONFIG,raceTaxRates:{...DEFAULT_ECONOMY_CONFIG.raceTaxRates,Люди:.12}});
const politics=calculateStatePolitics([politicsProvince('Корона'),politicsProvince('Знать')],[
  {group_type:'estate',group_key:'Корона',status:'Ключевое',loyalty:.8},
  {group_type:'estate',group_key:'Знать',status:'Ключевое',loyalty:.8},
  {group_type:'race',group_key:'1',status:'Официальная',loyalty:.5},
  {group_type:'religion',group_key:'2',status:'Признание',loyalty:.5},
],'Альфа');
assert.equal(politics.estateInfluence['Корона'],.5);
assert.equal(politics.estateLoyalty['Корона'],.75);
assert.equal(politics.estateLoyalty['Знать'],.75);
assert.ok(Math.abs(politics.stateStability-(0+.2+.95)/3)<1e-12);
setEconomyConfig({...DEFAULT_ECONOMY_CONFIG,raceTaxRates:{...DEFAULT_ECONOMY_CONFIG.raceTaxRates,Люди:.08}});
const belowBasePolitics=calculateStatePolitics([politicsProvince('Корона'),politicsProvince('Знать')],[
  {group_type:'estate',group_key:'Корона',status:'Ключевое',loyalty:.8},
  {group_type:'estate',group_key:'Знать',status:'Ключевое',loyalty:.8},
],'Альфа');
assert.ok(Math.abs(belowBasePolitics.estateLoyalty['Корона']-.85)<1e-12);
setEconomyConfig(DEFAULT_ECONOMY_CONFIG);
console.log('Economy calculations: baseline and occupation transfer assertions passed');
