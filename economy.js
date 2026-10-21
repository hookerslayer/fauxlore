// Deterministic, display-time economic calculations based on the reviewed
// technical-information tables in docs/economy.md. Derived values are never
// written back into province source data.
export const ECONOMY_RESOURCES = [
  ['Базовые','Зерно',1,.8,.5],['Базовые','Лес',1,.6,.3],['Базовые','Морепродукты',2,.4,.15],['Базовые','Животноводство',3,.3,.15],
  ['Промышленные','Соль',4,.35,.2],['Промышленные','Хлопок',4,.25,.15],['Промышленные','Металлы',5,.2,.15],['Промышленные','Мех',5,.2,.05],['Промышленные','Красители',6,.15,.05],
  ['Промышленные','Табак',6,.1,.05],['Промышленные','Селитра',7,.1,.05],['Роскошь','Фрукты',7,.15,.08],['Роскошь','Сахар',6,.1,.04],['Роскошь','Чай',6,.08,.03],
  ['Роскошь','Кофе',7,.08,.03],['Роскошь','Шёлк',8,.07,.03],['Роскошь','Жемчуг',9,.05,.02],['Особые','Драгоценные металлы',10,.1,.05],['Особые','Эфемера',10,.1,.01],
  ['Особые','Эфемерная пустошь',0,0,0],['Особые','Магическая пустошь',0,0,0],
].map(([category,name,value,production,consumption])=>({category,name,value,production,consumption,showInProduction:!name.endsWith('пустошь')}));

// All currently defined race and religion rates in the source workbook are 0.10 G.
export const RACE_TAX_RATES = Object.fromEntries(['Люди','Дварфы','Эльфы','Полуэльфы','Зверолюди'].map(name=>[name,.1]));
export const RELIGION_TAX_RATES = Object.fromEntries(['Единобожие','Жизнелизм','Стратерианство','Атомизм','Астроизм'].map(name=>[name,.1]));
export const PROVINCE_MODIFIERS = {
  'Столичная':{tax:2,production:1,trade:1.5,tradeBase:15},
  'Городская':{tax:1.5,production:.7,trade:1,tradeBase:10},
  'Регион':{tax:.8,production:1.2,trade:.5,tradeBase:2},
  'Территориальная':{tax:0,production:0,trade:0,tradeBase:0},
};
export const TRADE_STATUS_MODIFIERS = {
  'Отсутствует':1,'Устье реки':1.1,'Природный порт':1.25,
  'Центр торговли I':1.25,'Центр торговли II':1.45,'Центр торговли III':1.65,
};
export const PROVINCE_VALUE_WEIGHTS = {gold:.001,trade:.005,production:.005,recruits:.002,population:.0005};

const roundTo=(value,places)=>Math.round(value*10**places+Number.EPSILON)/10**places;
const resourceFor=province=>ECONOMY_RESOURCES.find(item=>item.name===province?.layers?.resources?.name);

export function calculateProvinceEconomy(province) {
  if(!province||province.kind!=='land')return {taxes:null,production:null,tradeInfluence:null,populationGrowth:null,missing:['not-land']};
  const type=PROVINCE_MODIFIERS[province.province_type];
  const resource=resourceFor(province);
  const missing=[];
  if(!type)missing.push('province-type');
  if(!resource&&province.layers?.resources?.name)missing.push('resource-coefficient');
  const controlPercent=province.control==null?100:Number(province.control);
  const control=Number.isInteger(controlPercent)&&controlPercent>=0&&controlPercent<=100?controlPercent/100:null;
  if(control===null)missing.push('control-modifier');
  const population=Math.max(0,Number(province.population)||0);
  const raceRate=RACE_TAX_RATES[province.layers?.races?.name];
  const religionRate=RELIGION_TAX_RATES[province.layers?.religions?.name];
  if(raceRate===undefined||religionRate===undefined)missing.push('tax-rate');
  const taxes=type&&control!==null&&raceRate!==undefined&&religionRate!==undefined
    ?roundTo(population/10*(raceRate+religionRate)*type.tax*control,2):null;
  const stateLayer=province.layers?.states;
  const rawCrime=stateLayer?Number(stateLayer.crime??.2):0;
  const crime=Number.isFinite(rawCrime)&&rawCrime>=0&&rawCrime<=1?rawCrime:null;
  if(crime===null)missing.push('crime-rate');
  const production=type&&resource&&control!==null&&crime!==null
    ?Math.round(population*resource.production*type.production*control*(1-crime)):null;
  const tradeStatus=province.trade_status||'Отсутствует';
  const tradeModifier=TRADE_STATUS_MODIFIERS[tradeStatus];
  if(tradeModifier===undefined)missing.push('trade-status-modifier');
  const tradeInfluence=type&&tradeModifier!==undefined?roundTo(type.tradeBase*type.trade*tradeModifier,2):null;
  const growthModifier={Люди:1,Дварфы:.8,Полуэльфы:.75,Эльфы:.35,Зверолюди:.6}[province.layers?.races?.name];
  const populationGrowth=growthModifier===undefined?null:Math.round(population*.03*growthModifier);
  if(populationGrowth===null)missing.push('race-growth-coefficient');
  return {taxes,production,tradeInfluence,populationGrowth,crime,missing};
}

// Current value follows the workbook's weighted components. The recruitment
// term remains zero until recruitment limit mechanics are implemented.
export function calculateProvinceValue(province) {
  const economy=calculateProvinceEconomy(province);
  if(economy.taxes===null||economy.tradeInfluence===null)return null;
  const resource=resourceFor(province);
  const productionGold=(economy.production??0)*(resource?.value??0);
  const population=Math.max(0,Number(province?.population)||0);
  const value=((economy.taxes+productionGold)*PROVINCE_VALUE_WEIGHTS.gold)
    +(economy.tradeInfluence*PROVINCE_VALUE_WEIGHTS.trade)
    +(productionGold*PROVINCE_VALUE_WEIGHTS.production)
    +(population*PROVINCE_VALUE_WEIGHTS.population);
  return Math.round(value);
}

export function calculateStateProduction(provinces) {
  const population=provinces.reduce((sum,p)=>sum+(Number(p.population)||0),0);
  return ECONOMY_RESOURCES.filter(resource=>resource.showInProduction).map(resource=>{
    const matching=provinces.filter(p=>p.layers?.resources?.name===resource.name);
    const calculations=matching.map(calculateProvinceEconomy);
    const production=calculations.every(item=>item.production!==null)
      ?calculations.reduce((sum,item)=>sum+item.production,0):null;
    const consumption=Math.ceil(population/10*resource.consumption);
    return {resource:resource.name,category:resource.category,population,production,consumption,balance:production===null?null:production-consumption,
      unresolved:calculations.some(item=>item.production===null)};
  });
}

// Compact, deterministic snapshot sent to the server when the administrator
// advances a turn. This records calculated outputs without inventing treasury
// or stockpile rules that have not yet been approved.
export function buildTurnEconomyReport(provinces) {
  const states=new Map();
  for(const province of provinces){
    if(province.kind!=='land'||!province.layers?.states?.id)continue;
    const id=Number(province.layers.states.id);
    if(!states.has(id))states.set(id,{id,name:province.layers.states.name,provinces:[]});
    states.get(id).provinces.push(province);
  }
  return [...states.values()].map(state=>{
    const population=state.provinces.reduce((sum,p)=>sum+(Number(p.population)||0),0);
    const calculations=state.provinces.map(calculateProvinceEconomy);
    const production=calculateStateProduction(state.provinces).map(row=>({resource:row.resource,
      produced:row.production,consumed:row.consumption,balance:row.balance}));
    const stateCrime=state.provinces.find(p=>p.layers?.states?.crime!=null)?.layers.states.crime??.2;
    return {id:state.id,name:state.name,province_count:state.provinces.length,population,crime:stateCrime,
      gross_taxes:roundTo(calculations.reduce((sum,item)=>sum+(item.taxes??0),0),2),
      unresolved_tax_provinces:calculations.filter(item=>item.taxes===null).length,
      population_growth:calculations.reduce((sum,item)=>sum+(item.populationGrowth??0),0),
      trade_influence:roundTo(calculations.reduce((sum,item)=>sum+(item.tradeInfluence??0),0),2),production};
  });
}

