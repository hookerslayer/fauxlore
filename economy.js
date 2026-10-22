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
export const RELIGION_TAX_RATES = Object.fromEntries(['Правоверие','Витализм','Единобожие','Жизнелизм','Стратерианство','Атомизм','Астроизм'].map(name=>[name,.1]));
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

export const RECRUIT_GROWTH_MODIFIERS={'Столичная':1.5,'Городская':1,'Регион':.5,'Территориальная':0};
export const RECRUIT_LIMIT_MODIFIERS={'Столичная':1.5,'Городская':1,'Регион':.5,'Территориальная':0};
export const ESTATE_RECRUIT_MODIFIERS={'Корона':1.5,'Знать':1.2,'Духовенство':.3,'Горожане':.5,'Крестьяне':.1};
export const ESTATE_NAMES=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
export const ESTATE_AMBITIONS={'Господствующее':0,'Ключевое':.5,'Значимое':.35,'Бесправное':0};
export const DEFAULT_ECONOMY_CONFIG={resources:ECONOMY_RESOURCES,raceTaxRates:RACE_TAX_RATES,religionTaxRates:RELIGION_TAX_RATES,provinceModifiers:PROVINCE_MODIFIERS,tradeStatusModifiers:TRADE_STATUS_MODIFIERS,raceGrowthModifiers:{Люди:1,Дварфы:.8,Полуэльфы:.75,Эльфы:.35,Зверолюди:.6},recruitGrowthModifiers:RECRUIT_GROWTH_MODIFIERS,recruitLimitModifiers:RECRUIT_LIMIT_MODIFIERS,estateRecruitModifiers:ESTATE_RECRUIT_MODIFIERS,provinceValueWeights:PROVINCE_VALUE_WEIGHTS,estateTaxGreed:{'Господствующее|Корона':0,'Господствующее|Знать':.6,'Господствующее|Духовенство':.5,'Господствующее|Горожане':.5,'Господствующее|Крестьяне':.4,'Ключевое|Корона':0,'Ключевое|Знать':.35,'Ключевое|Духовенство':.3,'Ключевое|Горожане':.3,'Ключевое|Крестьяне':.2,'Значимое|Корона':0,'Значимое|Знать':.2,'Значимое|Духовенство':.15,'Значимое|Горожане':.15,'Значимое|Крестьяне':.1,'Бесправное|Корона':0,'Бесправное|Знать':.05,'Бесправное|Духовенство':.05,'Бесправное|Горожане':.05,'Бесправное|Крестьяне':0},taxLoyaltySensitivity:.5,occupationMultiplier:.5};
let activeConfig=DEFAULT_ECONOMY_CONFIG;
export function setEconomyConfig(config){if(config&&typeof config==='object')activeConfig={...DEFAULT_ECONOMY_CONFIG,...config};}
export function getEconomyConfig(){return activeConfig;}

const roundTo=(value,places)=>Math.round(value*10**places+Number.EPSILON)/10**places;
const resourceFor=(province,config=activeConfig)=>(config.resources||ECONOMY_RESOURCES).find(item=>item.name===province?.layers?.resources?.name);
export const calculateProvinceShare=(province,beneficiary)=>{const occupation=province?.occupation,owner=province?.layers?.states?.name;if(!occupation||occupation===owner)return owner===beneficiary?1:beneficiary?0:1;return occupation===beneficiary?Number(activeConfig.occupationMultiplier??.5):0;};

export function calculateProvinceEconomy(province, beneficiary=province?.layers?.states?.name) {
  if(!province||province.kind!=='land')return {taxes:null,production:null,tradeInfluence:null,populationGrowth:null,recruitGrowth:null,recruitLimit:null,missing:['not-land']};
  const type=activeConfig.provinceModifiers?.[province.province_type];
  const resource=resourceFor(province);
  const share=calculateProvinceShare(province,beneficiary);
  const missing=[];
  if(!type)missing.push('province-type');
  if(!resource&&province.layers?.resources?.name)missing.push('resource-coefficient');
  const controlPercent=province.control==null?100:Number(province.control);
  const control=Number.isInteger(controlPercent)&&controlPercent>=0&&controlPercent<=100?controlPercent/100:null;
  if(control===null)missing.push('control-modifier');
  const population=Math.max(0,Number(province.population)||0);
  const stateLayer=province.layers?.states;
  const occupationRates=province.occupation&&province.occupation!==stateLayer?.name;
  const raceRate=occupationRates?province.occupation_race_tax_rates?.[province.layers?.races?.name]??activeConfig.raceTaxRates?.[province.layers?.races?.name]
    :stateLayer?.race_tax_rates?.[province.layers?.races?.name]??activeConfig.raceTaxRates?.[province.layers?.races?.name];
  const religionRate=occupationRates?province.occupation_religion_tax_rates?.[province.layers?.religions?.name]??activeConfig.religionTaxRates?.[province.layers?.religions?.name]
    :stateLayer?.religion_tax_rates?.[province.layers?.religions?.name]??activeConfig.religionTaxRates?.[province.layers?.religions?.name];
  if(raceRate===undefined||religionRate===undefined)missing.push('tax-rate');
  const taxes=type&&control!==null&&raceRate!==undefined&&religionRate!==undefined
    ?roundTo(population/10*(raceRate+religionRate)*type.tax*control*share,2):null;
  const rawCrime=stateLayer?Number(stateLayer.crime??.2):0;
  const crime=Number.isFinite(rawCrime)&&rawCrime>=0&&rawCrime<=1?rawCrime:null;
  if(crime===null)missing.push('crime-rate');
  const production=type&&resource&&control!==null&&crime!==null
    ?Math.round(population*resource.production*type.production*control*(1-crime)*share):null;
  const tradeStatus=province.trade_status||'Отсутствует';
  const tradeModifier=activeConfig.tradeStatusModifiers?.[tradeStatus];
  if(tradeModifier===undefined)missing.push('trade-status-modifier');
  const tradeInfluence=type&&tradeModifier!==undefined?roundTo(type.tradeBase*type.trade*tradeModifier*share,2):null;
  const growthModifier=activeConfig.raceGrowthModifiers?.[province.layers?.races?.name];
  const populationGrowth=growthModifier===undefined?null:province.layers?.states?.name===beneficiary?Math.round(population*.03*growthModifier):0;
  if(populationGrowth===null)missing.push('race-growth-coefficient');
  const recruitGrowthModifier=activeConfig.recruitGrowthModifiers?.[province.province_type];
  const recruitLimitModifier=activeConfig.recruitLimitModifiers?.[province.province_type];
  const estateRecruitModifier=province.belonging==='Отсутствует'||!province.belonging?0:activeConfig.estateRecruitModifiers?.[province.belonging];
  if(recruitGrowthModifier===undefined)missing.push('recruit-growth-modifier');
  if(recruitLimitModifier===undefined)missing.push('recruit-limit-modifier');
  if(estateRecruitModifier===undefined)missing.push('estate-recruit-modifier');
  const recruitGrowth=recruitGrowthModifier===undefined||control===null?null:Math.round(population/1000*recruitGrowthModifier*control*share);
  const recruitLimit=recruitLimitModifier===undefined||estateRecruitModifier===undefined||control===null?null:Math.round(population/100*recruitLimitModifier*estateRecruitModifier*control*share);
  return {taxes,production,tradeInfluence,populationGrowth,recruitGrowth,recruitLimit,crime,missing};
}

// Province value uses the workbook's weighted components. Recruitment limits
// are an appraisal component, not a stored recruit pool or treasury amount.
export function calculateProvinceValue(province, beneficiary=province?.layers?.states?.name) {
  const economy=calculateProvinceEconomy(province,beneficiary);
  if(economy.taxes===null||economy.tradeInfluence===null||economy.recruitLimit===null)return null;
  const resource=resourceFor(province);
  const productionGold=(economy.production??0)*(resource?.value??0);
  const population=Math.max(0,Number(province?.population)||0);
  const weights=activeConfig.provinceValueWeights||PROVINCE_VALUE_WEIGHTS;
  const value=((economy.taxes+productionGold)*weights.gold)
    +(economy.tradeInfluence*weights.trade)
    +(productionGold*weights.production)
    +(economy.recruitLimit*weights.recruits)
    +(population*weights.population*calculateProvinceShare(province,beneficiary));
  return Math.round(value);
}

const clamp01=value=>Math.max(0,Math.min(1,value));
export function calculateStatePolitics(provinces,politicsRows,stateName) {
  const rowsByKey=new Map((politicsRows||[]).map(row=>[`${row.group_type}:${row.group_key}`,row]));
  const estateWeights=Object.fromEntries(ESTATE_NAMES.map(name=>[name,0]));
  const estatePopulations=Object.fromEntries(ESTATE_NAMES.map(name=>[name,0]));
  const taxBurden=Object.fromEntries(ESTATE_NAMES.map(name=>[name,{actual:0,baseline:0,population:0}]));
  for(const province of provinces||[]) {
    if(province.kind!=='land')continue;
    const share=calculateProvinceShare(province,stateName);
    if(share<=0)continue;
    const estate=province.belonging;
    const population=Math.max(0,Number(province.population)||0);
    if(estateWeights[estate]!==undefined) {
      const value=calculateProvinceValue(province,stateName);
      if(value!==null)estateWeights[estate]+=value;
      if(province.layers?.states?.name===stateName)estatePopulations[estate]+=population;
      const race=province.layers?.races?.name,religion=province.layers?.religions?.name;
      const ownerRates=province.layers?.states;
      const occupationRates=province.occupation&&province.occupation!==ownerRates?.name;
      const raceRate=occupationRates?province.occupation_race_tax_rates?.[race]??activeConfig.raceTaxRates?.[race]:ownerRates?.race_tax_rates?.[race]??activeConfig.raceTaxRates?.[race];
      const religionRate=occupationRates?province.occupation_religion_tax_rates?.[religion]??activeConfig.religionTaxRates?.[religion]:ownerRates?.religion_tax_rates?.[religion]??activeConfig.religionTaxRates?.[religion];
      if(raceRate!==undefined&&religionRate!==undefined) {
        const effectivePopulation=population*share,entry=taxBurden[estate];
        entry.population+=effectivePopulation;
        entry.actual+=effectivePopulation*(Number(raceRate)+Number(religionRate));
        entry.baseline+=effectivePopulation*.2;
      }
    }
  }
  const totalWeight=ESTATE_NAMES.reduce((sum,name)=>sum+estateWeights[name],0);
  const estateInfluence={};
  const estateLoyalty={};
  const estateStability={};
  const estateStatusFactors={'Господствующее':1,'Ключевое':1.5,'Значимое':1,'Бесправное':.25};
  for(const name of ESTATE_NAMES) {
    const row=rowsByKey.get(`estate:${name}`);
    const influence=totalWeight?estateWeights[name]/totalWeight:0;
    const ambition=ESTATE_AMBITIONS[row?.status]??0;
    const burden=taxBurden[name];
    const rateRatio=burden.baseline?burden.actual/burden.baseline:1;
    const taxAdjustment=(rateRatio-1)*Number(activeConfig.taxLoyaltySensitivity??.5);
    const loyalty=clamp01(Number(row?.loyalty??.5)+influence-ambition-taxAdjustment);
    estateInfluence[name]=influence;
    estateLoyalty[name]=loyalty;
    const factor=estateStatusFactors[row?.status];
    estateStability[name]=factor===undefined?null:influence*(loyalty-.6)*2*factor;
  }
  const racialReligiousStability={race:0,religion:0};
  for(const groupType of ['race','religion']) {
    const field=groupType==='race'?'races':'religions',populations=new Map();
    for(const province of provinces||[]) {
      if(province.kind!=='land'||province.layers?.states?.name!==stateName)continue;
      const name=province.layers?.[field]?.name;if(!name)continue;
      populations.set(name,(populations.get(name)||0)+Math.max(0,Number(province.population)||0));
    }
    const total=[...populations.values()].reduce((sum,value)=>sum+value,0);
    let stability=0;
    for(const [name,population] of populations) {
      const categoryId=provinceCategoryId(provinces,field,name);
      const row=rowsByKey.get(`${groupType}:${categoryId}`);
      stability+=(total?population/total:0)*(Number(row?.loyalty??.5)-.5)*2;
    }
    racialReligiousStability[groupType]=clamp01(stability+(groupType==='religion'?.2:0));
  }
  const estateBlock=clamp01(.5+Object.values(estateStability).reduce((sum,value)=>sum+(value??0),0));
  const stateStability=(racialReligiousStability.race+racialReligiousStability.religion+estateBlock)/3;
  return {estateWeights,estateInfluence,estateLoyalty,estateStability,racialReligiousStability,estateBlock,stateStability};
}

function provinceCategoryId(provinces,layer,name) {
  for(const province of provinces||[])if(province.layers?.[layer]?.name===name&&province.layers[layer].id!=null)return province.layers[layer].id;
  return name;
}

export function calculateStateProduction(provinces, beneficiary) {
  const population=provinces.filter(p=>p.layers?.states?.name===beneficiary).reduce((sum,p)=>sum+(Number(p.population)||0),0);
  return (activeConfig.resources||ECONOMY_RESOURCES).filter(resource=>resource.showInProduction).map(resource=>{
    const matching=provinces.filter(p=>p.layers?.resources?.name===resource.name);
    const calculations=matching.map(p=>calculateProvinceEconomy(p,beneficiary));
    const production=calculations.every(item=>item.production!==null)
      ?calculations.reduce((sum,item)=>sum+item.production,0):null;
    const consumption=Math.ceil(population/10*resource.consumption);
    return {resource:resource.name,category:resource.category,population,production,consumption,balance:production===null?null:production-consumption,
      unresolved:calculations.some(item=>item.production===null)};
  });
}
