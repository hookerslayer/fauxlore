import assert from 'node:assert/strict';
import {calculateProvinceEconomy,calculateProvinceValue,calculateProvinceShare,calculateStateProduction,calculateStatePolitics,DEFAULT_ECONOMY_CONFIG,distributeTradeZoneIncome,setEconomyConfig} from '../economy.js';

const zoneIncomeSplit=distributeTradeZoneIncome(28);
assert.deepEqual(zoneIncomeSplit,{Корона:4.2,Знать:2.8,Духовенство:1.4,Горожане:18.2,Крестьяне:1.4});
assert.equal(Math.round(Object.values(distributeTradeZoneIncome(123.47)).reduce((sum,value)=>sum+value,0)*100),12347);

const province=(overrides={})=>({kind:'land',province_type:'Столичная',population:10000,belonging:'Корона',trade_status:'Центр торговли I',layers:{races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}},...overrides});
const capital=calculateProvinceEconomy(province());
assert.equal(capital.taxes,400);
assert.equal(capital.production,8000);
assert.equal(capital.tradeInfluence,28.13);
assert.equal(capital.populationGrowth,90);
const statusEffectsProvince=province({layers:{states:{id:10,name:'Альфа',crime:0,corruption:0,official_race_id:1,official_religion_id:2,
  race_statuses:{1:'Ассимиляция'},religion_statuses:{2:'Истребление'}},races:{id:1,name:'Люди'},religions:{id:2,name:'Атомизм'},resources:{name:'Зерно'}}});
const statusEffectsEconomy=calculateProvinceEconomy(statusEffectsProvince,'Альфа');
assert.equal(statusEffectsEconomy.taxes,260);
assert.equal(statusEffectsEconomy.production,2800);
assert.equal(statusEffectsEconomy.populationGrowth,0);
assert.equal(statusEffectsEconomy.recruitGrowth,0);
assert.equal(statusEffectsEconomy.recruitLimit,0);
for(const [multiplier,expected] of [[1,150],[.95,143],[.825,124],[.5,75]]){
  const p=province({layers:{states:{name:'Альфа',crime:0,corruption:0,urbanization_growth_multiplier:multiplier},races:{name:'Люди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}}});
  assert.equal(calculateProvinceEconomy(p,'Альфа').populationGrowth,expected);
}
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
const stateRateProvince=province({province_type:'Регион',population:2500,layers:{states:{id:1,name:'Альфа',crime:0,corruption:0,race_tax_rates:{Зверолюди:.2},religion_tax_rates:{Жизнелизм:.3}},races:{name:'Зверолюди'},religions:{name:'Жизнелизм'},resources:{name:'Зерно'}}});
assert.equal(calculateProvinceEconomy(stateRateProvince,'Альфа').taxes,100);
const occupiedRateProvince=province({province_type:'Регион',population:2500,occupation:'Бета',layers:{states:{id:1,name:'Альфа',crime:0,corruption:0,race_tax_rates:{Люди:.1},religion_tax_rates:{Атомизм:.1}},races:{name:'Люди'},religions:{name:'Атомизм'},resources:{name:'Зерно'}},occupation_crime:0,occupation_corruption:0,occupation_race_tax_rates:{Люди:.4},occupation_religion_tax_rates:{Атомизм:.5}});
assert.equal(calculateProvinceEconomy(occupiedRateProvince,'Бета').taxes,90);
const regionalRecruitment=calculateProvinceEconomy(province({province_type:'Регион',population:2500,belonging:'Крестьяне'}));
assert.equal(regionalRecruitment.recruitGrowth,1);
assert.equal(regionalRecruitment.recruitLimit,1);
assert.equal(calculateProvinceEconomy(province({belonging:'Отсутствует'})).recruitLimit,null);
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
const occupied=province({province_type:'Регион',population:10000,trade_status:'Отсутствует',occupation:'Бета',occupation_crime:0,occupation_corruption:0,layers:{states:{id:1,name:'Альфа',crime:.2,corruption:0},races:{name:'Люди'},religions:{name:'Астроизм'},resources:{name:'Зерно'}}});
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
const politicsProvince=(belonging)=>province({population:10000,belonging,trade_status:'Отсутствует',layers:{states:{id:1,name:'Альфа',crime:.2,corruption:0},races:{id:1,name:'Люди'},religions:{id:2,name:'Атомизм'},resources:{name:'Зерно'}}});
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
assert.ok(Math.abs(politics.stateStability-(.2+.3+.95)/3)<1e-12);
setEconomyConfig({...DEFAULT_ECONOMY_CONFIG,raceTaxRates:{...DEFAULT_ECONOMY_CONFIG.raceTaxRates,Люди:.08}});
const belowBasePolitics=calculateStatePolitics([politicsProvince('Корона'),politicsProvince('Знать')],[
  {group_type:'estate',group_key:'Корона',status:'Ключевое',loyalty:.8},
  {group_type:'estate',group_key:'Знать',status:'Ключевое',loyalty:.8},
],'Альфа');
assert.ok(Math.abs(belowBasePolitics.estateLoyalty['Корона']-.85)<1e-12);
setEconomyConfig(DEFAULT_ECONOMY_CONFIG);
// Stage 0: fixed political snapshots, including the fifth estate.
assert.ok(Math.abs(calculateStatePolitics([],[],'Пустое').stateStability-7/30)<1e-12);
const fiveEstates=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
const equalProvinces=fiveEstates.map(politicsProvince);
const equalPolitics=fiveEstates.map(group_key=>({group_type:'estate',group_key,status:'Ключевое',loyalty:.8}));
const five=calculateStatePolitics(equalProvinces,equalPolitics,'Альфа');
assert.ok(Math.abs(five.estateBlock-.2)<1e-12);
assert.ok(Math.abs(five.stateStability-2/15)<1e-12);
const fifth=calculateStatePolitics(equalProvinces,equalPolitics.map(row=>row.group_key==='Крестьяне'?{...row,loyalty:1}:row),'Альфа');
assert.ok(Math.abs(fifth.estateBlock-.32)<1e-12);
assert.ok(Math.abs(fifth.stateStability-13/75)<1e-12);
console.log('Economy calculations: baseline and occupation transfer assertions passed');

// State effects: deductions are applied once before the treasury split.
const effectsProvince=province({population:10000,province_type:'Столичная',layers:{states:{id:1,name:'Альфа',crime:.2,corruption:.2,urbanization_growth_multiplier:.95},races:{name:'Люди'},religions:{name:'Атомизм'},resources:{name:'Зерно'}}});
const effects=calculateProvinceEconomy(effectsProvince,'Альфа');
assert.equal(effects.grossTaxes,400);
assert.equal(effects.corruptionTaxLoss,80);
assert.equal(effects.crimeTaxLoss,16);
assert.equal(effects.taxes,304);
assert.equal(effects.populationGrowth,128);
assert.equal(effects.recruitGrowth,17);
assert.equal(effects.recruitLimit,225);
assert.equal(effects.production,6400);
const withCorruption=calculateStatePolitics(equalProvinces,equalPolitics,'Альфа',{corruption:.9});
assert.ok(Math.abs(withCorruption.estateLoyalty['Знать']-.65)<1e-12);
assert.ok(Math.abs(withCorruption.estateLoyalty['Духовенство']-.65)<1e-12);
assert.ok(Math.abs(withCorruption.estateLoyalty['Крестьяне']-.5)<1e-12);
const occupiedEffects=calculateProvinceEconomy({...effectsProvince,occupation:'Бета',occupation_crime:1,occupation_corruption:.9},'Бета');
assert.equal(occupiedEffects.grossTaxes,200);
assert.equal(occupiedEffects.taxes,15);
assert.equal(occupiedEffects.production,3200);
assert.equal(occupiedEffects.populationGrowth,0);
assert.equal(occupiedEffects.recruitGrowth,11);
assert.equal(occupiedEffects.recruitLimit,113);
console.log('State effects: net tax, corruption loyalty, crime and occupation assertions passed');
