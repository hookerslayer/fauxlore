import {estatePopulation, BASE_ESTATE_TAX_RATES, developmentMultiplier, provinceTaxEfficiency} from './estate-demography.js';

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

export const PROVINCE_MODIFIERS = {
  'Столичная':{tax:1,production:1,trade:1.5,tradeBase:15},
  'Городская':{tax:1,production:.7,trade:1,tradeBase:10},
  'Регион':{tax:1,production:1.2,trade:.5,tradeBase:2},
};
export const TRADE_STATUS_MODIFIERS = {
  'Отсутствует':1,'Устье реки':1.1,'Природный порт':1.25,
  'Центр торговли I':1.25,'Центр торговли II':1.45,'Центр торговли III':1.65,
};
export const PROVINCE_VALUE_WEIGHTS = {gold:.001,trade:.005,production:.005,recruits:.002,population:.0005};

export const RECRUIT_GROWTH_MODIFIERS={'Столичная':1.5,'Городская':1,'Регион':.5};
export const RECRUIT_LIMIT_MODIFIERS={'Столичная':1.5,'Городская':1,'Регион':.5};
export const ESTATE_RECRUIT_MODIFIERS={'Знать':1.2,'Духовенство':.3,'Горожане':.5,'Крестьяне':.1};
export const ESTATE_NAMES=['Знать','Духовенство','Горожане','Крестьяне'];
export const ESTATE_AMBITIONS={'Ключевое':.5,'Значимое':.35,'Бесправное':0};
export const ESTATE_INFLUENCE_FACTORS={'Ключевое':3,'Значимое':1.5,'Бесправное':.25};
export const DEFAULT_ECONOMY_CONFIG={resources:ECONOMY_RESOURCES,estateTaxRates:BASE_ESTATE_TAX_RATES,provinceModifiers:PROVINCE_MODIFIERS,tradeStatusModifiers:TRADE_STATUS_MODIFIERS,raceGrowthModifiers:{Люди:1,Дварфы:.8,Полуэльфы:.75,Эльфы:.35,Зверолюди:.6},recruitGrowthModifiers:RECRUIT_GROWTH_MODIFIERS,recruitLimitModifiers:RECRUIT_LIMIT_MODIFIERS,estateRecruitModifiers:ESTATE_RECRUIT_MODIFIERS,provinceValueWeights:PROVINCE_VALUE_WEIGHTS,estateTaxGreed:{'Ключевое|Знать':.35,'Ключевое|Духовенство':.3,'Ключевое|Горожане':.3,'Ключевое|Крестьяне':.2,'Значимое|Знать':.2,'Значимое|Духовенство':.15,'Значимое|Горожане':.15,'Значимое|Крестьяне':.1,'Бесправное|Знать':.05,'Бесправное|Духовенство':.05,'Бесправное|Горожане':.05,'Бесправное|Крестьяне':0},taxLoyaltySensitivity:.5,occupationMultiplier:.5};
let activeConfig=DEFAULT_ECONOMY_CONFIG;
export const DEFAULT_STATE_EFFECTS={crimeTaxPenalty:.25,crimePopulationPenalty:.5,crimeRecruitBonus:.5,corruptionTaxPenalty:1,corruptionLoyaltyDivisor:6,corruptionLoyaltyCap:.15,overloadCorruptionPerRatio:1,overloadCorruptionCapPP:3,corruptionRecoveryCapPP:1,corruptionGrowthCapPP:3,urbanizationThreshold:.15,urbanizationPenaltySlope:.5,urbanizationPenaltyCap:.5};
export function setEconomyConfig(config){if(config&&typeof config==='object')activeConfig={...DEFAULT_ECONOMY_CONFIG,...config,stateEffects:{...DEFAULT_STATE_EFFECTS,...config.stateEffects}};}
export function getEconomyConfig(){return activeConfig;}

const floorToInteger=value=>Math.floor(Number(value)||0);
const roundTo=value=>floorToInteger(value);
export const GROUP_STATUS_EFFECTS={'Официальная':{population:1.1,tax:1,production:1,recruit:1},'Признание':{population:1,tax:1,production:1,recruit:1},'Невмешательство':{population:1,tax:1,production:1,recruit:1},'Ассимиляция':{population:.5,tax:.8,production:.7,recruit:0},'Истребление':{population:0,tax:.5,production:.5,recruit:0}};
function groupStatusForProvince(province,groupType){
  const categoryLayer=groupType==='race'?'races':'religions',stateLayer=province?.layers?.states,categoryId=province?.layers?.[categoryLayer]?.id;
  const occupied=province?.occupation&&province.occupation!==stateLayer?.name;
  const map=occupied?province?.[`occupation_${groupType}_statuses`]:stateLayer?.[`${groupType}_statuses`];
  const officialId=stateLayer?.[`official_${groupType}_id`];
  return map?.[categoryId]||(categoryId!=null&&officialId!=null&&String(categoryId)===String(officialId)?'Официальная':'Невмешательство');
}
const groupStatusEffect=(province,groupType,metric)=>GROUP_STATUS_EFFECTS[groupStatusForProvince(province,groupType)]?.[metric]??1;
const resourceFor=(province,config=activeConfig)=>(config.resources||ECONOMY_RESOURCES).find(item=>item.name===province?.layers?.resources?.name);
export const calculateProvinceShare=(province,beneficiary)=>{const occupation=province?.occupation,owner=province?.layers?.states?.name;if(!occupation||occupation===owner)return owner===beneficiary?1:beneficiary?0:1;return occupation===beneficiary?Number(activeConfig.occupationMultiplier??.5):0;};

function provincePermanentModifier(province,stateContext,key){
  const principles=stateContext?.principles||province?.layers?.states?.principles||{};
  const type=province?.province_type,race=province?.layers?.races?.name,religion=province?.layers?.religions?.name;
  const resource=province?.layers?.resources?.name,hasRace=name=>race===name,hasReligion=name=>religion===name;
  let value=0;
  if(key==='tax_efficiency'){
    if(principles.authority==='Диктат'||principles.structure==='Деспотизм')value+=.10;
    if(principles.authority==='Магистрат'&&['Городская','Столичная'].includes(type))value+=.10;
    if(hasRace('Эльфы'))value+=.20;
    if(hasReligion('Правоверие'))value+=.15;
  }else if(key==='production'){
    if(principles.economy==='Крепостничество')value+=.50;
    if(principles.economy==='Работорговля')value+=1;
    if(principles.economy==='Корсарство')value-=.20;
    if(principles.structure==='Ленное право'&&type==='Регион')value+=.10;
    if((principles.structure==='Консорциум'||principles.economy==='Гильдии')&&['Городская','Столичная'].includes(type))value+=.20;
    if(hasRace('Дварфы')&&['Металлы','Драгоценные металлы'].includes(resource))value+=.20;
    if(hasRace('Полуэльфы')&&resource==='Эфемера')value+=3;
  }else if(key==='trade_influence'){
    if(principles.authority==='Магистрат'&&['Городская','Столичная'].includes(type))value+=.15;
    if(principles.structure==='Консорциум')value+=.15;
    if(['Гильдии','Адмиралтейство'].includes(principles.economy))value+=.15;
    if(principles.economy==='Корсарство')value-=.15;
    if(hasReligion('Стратерианство'))value+=.10;
  }else if(key==='recruit_growth'){
    if(principles.authority==='Династия')value-=.10;
    if(principles.authority==='Клир')value-=.20;
    if(principles.authority==='Диктат')value+=.20;
    if(principles.structure==='Деспотизм'||principles.structure==='Командорство')value+=.10;
    if(principles.economy==='Корсарство')value+=.30;
    if(principles.economy==='Работорговля')value+=.20;
    if(principles.military==='Гвардия')value+=1;
    if(principles.authority==='Вече'&&type==='Регион')value+=.10;
    if(hasRace('Зверолюди'))value+=1;
    if(hasReligion('Атомизм'))value-=.20;
  }else if(key==='recruit_limit'){
    if(principles.authority==='Династия')value-=.10;
    if(principles.authority==='Клир')value-=.20;
    if(principles.military==='Гвардия')value+=1;
    if(principles.economy==='Работорговля')value+=.20;
    if(hasRace('Зверолюди'))value+=1;
    if(hasReligion('Атомизм'))value-=.20;
  }else if(key==='population_growth'){
    if(hasRace('Люди'))value+=.01;
    if(hasRace('Эльфы'))value-=.02;
    if(hasRace('Полуэльфы'))value-=.01;
    if(hasRace('Зверолюди')&&resource==='Животноводство')value+=.10;
  }
  const localAliases={recruit_growth:['local_recruit_growth','regional_recruit_growth'],recruit_limit:['local_recruit_limit'],production:['regional_production','urban_production','metal_production','ephemera_production']};
  for(const item of stateContext?.permanent_modifiers||[]){
    if(item.source_kind!=='admin'||![key,...(localAliases[key]||[])].includes(item.key))continue;
    if(item.target_province_id!=null&&Number(item.target_province_id)!==Number(province.id))continue;
    if(item.key==='regional_production'&&type!=='Регион'||item.key==='urban_production'&&!['Городская','Столичная'].includes(type))continue;
    if(item.key==='metal_production'&&!['Металлы','Драгоценные металлы'].includes(resource)||item.key==='ephemera_production'&&resource!=='Эфемера')continue;
    value+=Number(item.value)||0;
  }
  return value;
}
function provincePopulationGrowthMultiplier(province){
  return province?.layers?.races?.name==='Зверолюди'&&province?.layers?.resources?.name==='Животноводство'?1.10:1;
}

export function calculateProvinceEstateTaxes(province,beneficiary=province?.layers?.states?.name,stateContext=null){
  if(province?.kind!=='land')return null;
  const population=Math.max(0,Number(province.population)||0),counts=estatePopulation(province.province_type,population);
  const type=activeConfig.provinceModifiers?.[province.province_type],control=Number(province.control??100),development=developmentMultiplier(province.development??100),taxEfficiency=Math.max(0,Math.min(1,provinceTaxEfficiency(province.province_type)+provincePermanentModifier(province,stateContext,'tax_efficiency')));
  const occupied=province.occupation&&province.occupation!==province.layers?.states?.name;
  const rates=occupied?province.occupation_estate_tax_rates??activeConfig.estateTaxRates:province.layers?.states?.estate_tax_rates??activeConfig.estateTaxRates;
  if(!counts||!type||development===null||taxEfficiency===null||!Number.isFinite(control)||control<0||control>100)return null;
  const effects={...DEFAULT_STATE_EFFECTS,...activeConfig.stateEffects},crime=Number(occupied?province.occupation_crime??.2:province.layers?.states?.crime??(province.layers?.states?.name ? .2 : 0)),corruption=Number(occupied?province.occupation_corruption??.2:province.layers?.states?.corruption??(province.layers?.states?.name ? .2 : 0));
  if(!Number.isFinite(crime)||!Number.isFinite(corruption))return null;
  const share=calculateProvinceShare(province,beneficiary),result={};
  for(const [estate,count] of Object.entries(counts)){
    const rate=Number(rates?.[estate]);if(!Number.isFinite(rate)||rate<0)return null;
    const gross=floorToInteger(count*rate*share*Math.min(1,development));
    const corruptionLoss=floorToInteger(gross*corruption*effects.corruptionTaxPenalty);
    const crimeLoss=floorToInteger((gross-corruptionLoss)*crime*effects.crimeTaxPenalty);
    const beforeCollectionEfficiency=floorToInteger(gross-corruptionLoss-crimeLoss);
    result[estate]={population:count,gross,corruptionLoss,crimeLoss,net:floorToInteger(beforeCollectionEfficiency*taxEfficiency*control/100)};
  }
  return result;
}

export function calculateProvinceEconomy(province, beneficiary=province?.layers?.states?.name,stateContext=null) {
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
  const development=developmentMultiplier(province.development??100);
  if(development===null)missing.push('development');
  const effects={...DEFAULT_STATE_EFFECTS,...activeConfig.stateEffects};
  const recipientCrime=Number(occupationRates?province.occupation_crime??.2:stateLayer?.crime??(stateLayer ? .2 : 0));
  const recipientCorruption=Number(occupationRates?province.occupation_corruption??.2:stateLayer?.corruption??(stateLayer ? .2 : 0));
  const estateLines=calculateProvinceEstateTaxes(province,beneficiary,stateContext);
  const grossTaxes=estateLines?floorToInteger(Object.values(estateLines).reduce((sum,line)=>sum+line.gross,0)):null;
  if(grossTaxes===null)missing.push('estate-tax-rate');
  const corruptionTaxLoss=estateLines?floorToInteger(Object.values(estateLines).reduce((sum,line)=>sum+line.corruptionLoss,0)):null;
  const crimeTaxLoss=estateLines?floorToInteger(Object.values(estateLines).reduce((sum,line)=>sum+line.crimeLoss,0)):null;
  const taxes=estateLines?floorToInteger(Object.values(estateLines).reduce((sum,line)=>sum+line.net,0)):null;
  const rawCrime=stateLayer||province.occupation?recipientCrime:0;
  const crime=Number.isFinite(rawCrime)&&rawCrime>=0&&rawCrime<=1?rawCrime:null;
  if(crime===null)missing.push('crime-rate');
  const production=type&&resource&&control!==null&&crime!==null&&development!==null
    ?floorToInteger(population*resource.production*type.production*control*(1-crime)*share*(1+provincePermanentModifier(province,stateContext,'production'))*groupStatusEffect(province,'race','production')*groupStatusEffect(province,'religion','production')*development):null;
  const tradeStatus=province.trade_status||'Отсутствует';
  const tradeModifier=activeConfig.tradeStatusModifiers?.[tradeStatus];
  if(tradeModifier===undefined)missing.push('trade-status-modifier');
  const tradeInfluence=type&&tradeModifier!==undefined&&development!==null?roundTo(type.tradeBase*type.trade*tradeModifier*share*development*(1+provincePermanentModifier(province,stateContext,'trade_influence')),2):null;
  const growthModifier=activeConfig.raceGrowthModifiers?.[province.layers?.races?.name];
  const urbanizationGrowthMultiplier=Number(stateLayer?.urbanization_growth_multiplier??1);
  const raceGrowthAdjustment=provincePermanentModifier(province,stateContext,'population_growth');
  const populationGrowth=growthModifier===undefined||development===null?null:province.layers?.states?.name===beneficiary?floorToInteger(population*Math.max(0,.015*growthModifier*(1+raceGrowthAdjustment))*provincePopulationGrowthMultiplier(province)*urbanizationGrowthMultiplier*(1-(crime??0)*effects.crimePopulationPenalty)*groupStatusEffect(province,'race','population')*groupStatusEffect(province,'religion','population')*development):0;
  if(populationGrowth===null)missing.push('race-growth-coefficient');
  const recruitGrowthModifier=activeConfig.recruitGrowthModifiers?.[province.province_type];
  const recruitLimitModifier=activeConfig.recruitLimitModifiers?.[province.province_type];
  const estateCounts=estatePopulation(province.province_type,population);
  const estateRecruitModifier=estateCounts&&population>0?Object.entries(estateCounts).reduce((sum,[estate,count])=>sum+count*Number(activeConfig.estateRecruitModifiers?.[estate]??0),0)/population:0;
  if(recruitGrowthModifier===undefined)missing.push('recruit-growth-modifier');
  if(recruitLimitModifier===undefined)missing.push('recruit-limit-modifier');
  if(!estateCounts)missing.push('estate-population');
  const recruitEffect=groupStatusEffect(province,'race','recruit')*groupStatusEffect(province,'religion','recruit');
  const recruitGrowth=recruitGrowthModifier===undefined||control===null||development===null?null:floorToInteger(population/1000*recruitGrowthModifier*control*share*(1+provincePermanentModifier(province,stateContext,'recruit_growth'))*(1+recipientCrime*effects.crimeRecruitBonus)*recruitEffect*development);
  const recruitLimit=recruitLimitModifier===undefined||!estateCounts||control===null||development===null?null:floorToInteger(population/10*recruitLimitModifier*estateRecruitModifier*control*share*(1+provincePermanentModifier(province,stateContext,'recruit_limit'))*recruitEffect*development);
  return {taxes,grossTaxes,corruptionTaxLoss,crimeTaxLoss,production,tradeInfluence,populationGrowth,recruitGrowth,recruitLimit,crime,missing};
}

// Province value uses the workbook's weighted components. Recruitment limits
// are an appraisal component, not a stored recruit pool or treasury amount.
export function calculateProvinceValue(province, beneficiary=province?.layers?.states?.name,stateContext=null) {
  const economy=calculateProvinceEconomy(province,beneficiary,stateContext);
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
  return floorToInteger(value);
}

const clamp01=value=>Math.max(0,Math.min(1,value));
export const GROUP_STATUS_LOYALTY_MODIFIERS={'Официальная':.1,'Признание':.05,'Невмешательство':0,'Ассимиляция':-.1,'Истребление':-.25};
function calculateGroupStability(populations,loyaltyForGroup) {
  const total=[...populations.values()].reduce((sum,value)=>sum+value,0);
  const stability={};
  if(total<=0)return stability;
  for(const [key,population] of populations) {
    if(population<=0)continue;
    const loyalty=loyaltyForGroup(key);
    stability[key]=(population/total)*(loyalty-.5)*2;
  }
  return stability;
}
export function calculateStatePolitics(provinces,politicsRows,stateName,stateContext=null) {
  const effects={...DEFAULT_STATE_EFFECTS,...activeConfig.stateEffects};
  const state=provinces.find(p=>p.layers?.states?.name===stateName)?.layers?.states;
  const occupied=provinces.find(p=>p.occupation===stateName);
  const corruption=Number(stateContext?.corruption??state?.corruption??occupied?.occupation_corruption??(state ? .2 : 0));
  const rowsByKey=new Map((politicsRows||[]).map(row=>[`${row.group_type}:${row.group_key}`,row]));
  const estateWeights=Object.fromEntries(ESTATE_NAMES.map(name=>[name,0]));
  const estatePopulations=Object.fromEntries(ESTATE_NAMES.map(name=>[name,0]));
  const taxBurden=Object.fromEntries(ESTATE_NAMES.map(name=>[name,{actual:0,baseline:0,population:0}]));
  for(const province of provinces||[]) {
    if(province.kind!=='land')continue;
    const share=calculateProvinceShare(province,stateName);
    if(share<=0)continue;
    const population=Math.max(0,Number(province.population)||0);
    const counts=estatePopulation(province.province_type,population);
    if(!counts)continue;
    const value=calculateProvinceValue(province,stateName,stateContext);
    const rates=province.occupation&&province.occupation!==province.layers?.states?.name
      ?province.occupation_estate_tax_rates??activeConfig.estateTaxRates
      :province.layers?.states?.estate_tax_rates??activeConfig.estateTaxRates;
    for(const [estate,count] of Object.entries(counts)){
      if(value!==null&&population>0)estateWeights[estate]+=value*count/population;
      if(province.layers?.states?.name===stateName)estatePopulations[estate]+=count;
      const effectivePopulation=count*share,entry=taxBurden[estate];
      entry.population+=effectivePopulation;
      entry.actual+=effectivePopulation*Number(rates?.[estate]??BASE_ESTATE_TAX_RATES[estate]);
      entry.baseline+=effectivePopulation*BASE_ESTATE_TAX_RATES[estate];
    }
  }
  const estateEconomicWeights={...estateWeights};
  const listedModifiers=Array.isArray(stateContext?.permanent_modifiers)?stateContext.permanent_modifiers:null;
  const modifierTotal=(key,predicate=()=>true)=>listedModifiers
    ?listedModifiers.filter(item=>item.key===key&&item.target_province_id==null&&predicate(item)).reduce((sum,item)=>sum+(Number(item.value)||0),0)
    :null;
  for(const name of ESTATE_NAMES){
    const status=rowsByKey.get(`estate:${name}`)?.status;
    estateWeights[name]*=ESTATE_INFLUENCE_FACTORS[status]??1;
    const principles=stateContext?.principles||state?.principles||{};
    if(name==='Крестьяне'){
      const modifier=modifierTotal('peasant_influence');
      estateWeights[name]*=Math.max(0,1+(modifier??((principles.economy==='Крепостничество'?-.10:0)+(principles.economy==='Работорговля'?-.20:0))));
    }
  }
  const totalWeight=ESTATE_NAMES.reduce((sum,name)=>sum+estateWeights[name],0);
  const estateInfluence={};
  const estateLoyalty={};
  const estateStability={};
  const estateModifierBreakdown={};
  const estateStatusFactors={'Ключевое':1.5,'Значимое':1,'Бесправное':.25};
  const principles=stateContext?.principles||state?.principles||{};
  const activeElfFaith=(provinces||[]).some(p=>p.kind==='land'&&p.layers?.states?.name===stateName&&p.layers?.races?.name==='Эльфы');
  const activeOrthodoxy=(provinces||[]).some(p=>p.kind==='land'&&p.layers?.states?.name===stateName&&p.layers?.religions?.name==='Правоверие');
  for(const name of ESTATE_NAMES) {
    const row=rowsByKey.get(`estate:${name}`);
    const influence=totalWeight?estateWeights[name]/totalWeight:0;
    const ambition=ESTATE_AMBITIONS[row?.status]??0;
    const burden=taxBurden[name];
    const rateRatio=burden.baseline?burden.actual/burden.baseline:1;
    const taxAdjustment=(rateRatio-1)*Number(activeConfig.taxLoyaltySensitivity??.5);
    const bonus=['Знать','Духовенство'].includes(name)?Math.min(effects.corruptionLoyaltyCap,corruption/effects.corruptionLoyaltyDivisor):0;
    const fallbackLoyalty=(principles.authority==='Клир'?.10:0)
      +(principles.authority==='Вече'&&name==='Крестьяне'?.10:0)
      +(principles.economy==='Крепостничество'&&name==='Знать'?.10:0)
      -(principles.economy==='Крепостничество'&&name==='Крестьяне'?.10:0)
      -(principles.economy==='Работорговля'&&name==='Крестьяне'?.10:0);
    const principleLoyalty=listedModifiers
      ?modifierTotal('estate_loyalty')+(name==='Знать'?modifierTotal('nobility_loyalty'):0)+(name==='Крестьяне'?modifierTotal('peasant_loyalty'):0)
      :fallbackLoyalty;
    const loyalty=clamp01(Number(row?.loyalty??.5)+influence-ambition-taxAdjustment+bonus+principleLoyalty);
    estateInfluence[name]=influence;
    estateLoyalty[name]=loyalty;
    const factor=estateStatusFactors[row?.status];
    estateStability[name]=factor===undefined?null:influence*(loyalty-.6)*2*factor;
    estateModifierBreakdown[name]={baseLoyalty:Number(row?.loyalty??.5),economicWeight:estateEconomicWeights[name],statusWeightFactor:ESTATE_INFLUENCE_FACTORS[row?.status]??1,influence,status:row?.status||'—',ambition,taxAdjustment,corruptionBonus:bonus,principleLoyalty,effectiveLoyalty:loyalty,stabilityFactor:factor??null};
  }
  const racialReligiousStability={race:0,religion:0};
  const raceStability={},religionStability={},raceLoyalty={},religionLoyalty={};
  const raceModifierBreakdown={},religionModifierBreakdown={};
  for(const groupType of ['race','religion']) {
    const field=groupType==='race'?'races':'religions',populations=new Map();
    for(const province of provinces||[]) {
      if(province.kind!=='land'||province.layers?.states?.name!==stateName)continue;
      const name=province.layers?.[field]?.name;if(!name)continue;
      const key=provinceCategoryId(provinces,field,name);
      populations.set(key,(populations.get(key)||0)+Math.max(0,Number(province.population)||0));
    }
    const totalPopulation=[...populations.values()].reduce((sum,value)=>sum+value,0);
    const values=calculateGroupStability(populations,categoryId=>{
      const row=rowsByKey.get(`${groupType}:${categoryId}`);
      const groupName=(provinces||[]).find(p=>p.layers?.[field]?.id!=null&&String(p.layers[field].id)===String(categoryId))?.layers?.[field]?.name;
      let principleLoyalty=0;
      if(['Невмешательство','Ассимиляция','Истребление'].includes(row?.status||'Невмешательство')){
        if(listedModifiers)principleLoyalty=modifierTotal(groupType==='race'?'other_race_loyalty':'other_religion_loyalty',item=>item.source_kind==='admin'||item.source!==groupName);
        else if(groupType==='race'&&activeElfFaith&&groupName!=='Эльфы'||groupType==='religion'&&activeOrthodoxy&&groupName!=='Правоверие')principleLoyalty=-.10;
      }
      const loyalty=clamp01(Number(row?.loyalty??.5)+(GROUP_STATUS_LOYALTY_MODIFIERS[row?.status]??0)+principleLoyalty);
      (groupType==='race'?raceLoyalty:religionLoyalty)[categoryId]=loyalty;
      (groupType==='race'?raceModifierBreakdown:religionModifierBreakdown)[categoryId]={status:row?.status||'Невмешательство',baseLoyalty:Number(row?.loyalty??.5),loyaltyModifier:GROUP_STATUS_LOYALTY_MODIFIERS[row?.status]??0,permanentLoyalty:principleLoyalty,effectiveLoyalty:loyalty,population:populations.get(categoryId)||0,totalPopulation};
      return loyalty;
    });
    Object.assign(groupType==='race'?raceStability:religionStability,values);
    const stability=Object.values(values).reduce((sum,value)=>sum+value,0);
    racialReligiousStability[groupType]=clamp01(stability+(groupType==='religion'?.2:0));
  }
  const estateBlock=clamp01(.5+Object.values(estateStability).reduce((sum,value)=>sum+(value??0),0));
  const stateStability=(racialReligiousStability.race+racialReligiousStability.religion+estateBlock)/3;
  return {estateWeights,estateEconomicWeights,estateInfluence,estateLoyalty,estateStability,estateModifierBreakdown,raceLoyalty,religionLoyalty,raceStability,religionStability,raceModifierBreakdown,religionModifierBreakdown,racialReligiousStability,estateBlock,stateStability};
}

function provinceCategoryId(provinces,layer,name) {
  for(const province of provinces||[])if(province.layers?.[layer]?.name===name&&province.layers[layer].id!=null)return province.layers[layer].id;
  return name;
}

export function calculateStateProduction(provinces, beneficiary,stateContext=null) {
  const population=provinces.filter(p=>p.layers?.states?.name===beneficiary).reduce((sum,p)=>sum+(Number(p.population)||0),0);
  const hasRace=name=>provinces.some(p=>p.kind==='land'&&p.layers?.states?.name===beneficiary&&p.layers?.races?.name===name);
  const hasReligion=name=>provinces.some(p=>p.kind==='land'&&p.layers?.states?.name===beneficiary&&p.layers?.religions?.name===name);
  return (activeConfig.resources||ECONOMY_RESOURCES).filter(resource=>resource.showInProduction).map(resource=>{
    const matching=provinces.filter(p=>p.layers?.resources?.name===resource.name);
    const calculations=matching.map(p=>calculateProvinceEconomy(p,beneficiary,stateContext));
    const production=calculations.every(item=>item.production!==null)
      ?calculations.reduce((sum,item)=>sum+item.production,0):null;
    const principles=stateContext?.principles||{};
    let consumptionModifier=(['Гильдии','Адмиралтейство'].includes(principles.economy)?.10:0)
      +(hasReligion('Стратерианство')?-.20:0)
      +(principles.authority==='Клир'?(resource.name==='Драгоценные металлы'?.50:-.10):0)
      +(principles.authority==='Династия'&&resource.name==='Драгоценные металлы'?.10:0)
      +(hasRace('Эльфы')&&resource.name==='Драгоценные металлы'?.20:0);
    const consumption=floorToInteger(population/10*resource.consumption*Math.max(0,1+consumptionModifier));
    return {resource:resource.name,category:resource.category,population,production,consumption,balance:production===null?null:production-consumption,
      unresolved:calculations.some(item=>item.production===null)};
  });
}

export const TRADE_ELASTICITIES={Зерно:.4,Лес:.6,Морепродукты:.7,Животноводство:.8,Соль:.4,Хлопок:1,Металлы:1.2,Мех:1.5,Красители:1.9,Табак:1.3,Селитра:2.2,Фрукты:1.4,Сахар:1.7,Чай:1.6,Кофе:1.6,Шёлк:2.5,Жемчуг:3,'Драгоценные металлы':2.8,Эфемера:4.5};
export const TRADE_ZONE_INCOME_SHARES={'Корона':.15,'Знать':.10,'Духовенство':.05,'Горожане':.65,'Крестьяне':.05};
export function distributeTradeZoneIncome(amount){
  const total=Math.max(0,roundTo(Number(amount)||0)),result={};let allocated=0;
  for(const estate of ['Корона','Знать','Духовенство','Горожане']){result[estate]=roundTo(total*TRADE_ZONE_INCOME_SHARES[estate]);allocated+=result[estate];}
  result['Крестьяне']=roundTo(total-allocated);
  return result;
}
export function calculateTradeTargetPrice(basePrice,demand,supply,resourceName){
  const base=Number(basePrice)||0;if(base<=0)return 0;
  const ratio=Math.max(0,Number(demand)||0)/Math.max(Number(supply)||0,.0001);
  return Math.round(base*Math.max(.2,Math.min(5,Math.pow(ratio,TRADE_ELASTICITIES[resourceName]??0)))*10000)/10000;
}
export function calculateTradePrice(basePrice,demand,supply,resourceName,previousPrice=basePrice){
  const base=Number(basePrice)||0;if(base<=0)return 0;
  const target=calculateTradeTargetPrice(base,demand,supply,resourceName);
  const minimum=base*.2,maximum=base*5;
  const previous=Math.max(minimum,Math.min(maximum,Number(previousPrice)>0?Number(previousPrice):base));
  const delta=Math.max(-previous*.1,Math.min(previous*.1,target-previous));
  return Math.round(Math.max(minimum,Math.min(maximum,previous+delta))*10000)/10000;
}
export function calculateInternalTradeForecast(productionRows,dutyRate=15,previousPrices=new Map()){
  const resources=(productionRows||[]).map(row=>{
    const config=(activeConfig.resources||ECONOMY_RESOURCES).find(item=>item.name===row.resource);
    const basePrice=Number(config?.value)||0,demand=Math.max(0,Number(row.consumption)||0),supply=Math.max(0,Number(row.production)||0);
    const previousValue=Number(previousPrices.get?.(row.resource)??previousPrices[row.resource]??basePrice);
    const previousPrice=previousValue>0?previousValue:basePrice;
    const dynamicPrice=calculateTradePrice(basePrice,demand,supply,row.resource,previousPrice),quantity=Math.min(supply,demand);
    const turnover=floorToInteger(quantity*dynamicPrice),dutyIncome=floorToInteger(quantity*dynamicPrice*Number(dutyRate||0)/100);
    return {resource_name:row.resource,production:supply,consumption:demand,balance:row.balance,base_price:basePrice,dynamic_price:dynamicPrice,
      price_trend:dynamicPrice>previousPrice?'up':dynamicPrice<previousPrice?'down':'stable',
      contract_import:0,contract_export:0,zone_import:0,zone_export:0,internal_quantity:quantity,turnover,duty_income:dutyIncome};
  });
  const dutyIncome=resources.reduce((sum,row)=>sum+row.duty_income,0);
  const estatePool=Math.max(0,resources.reduce((sum,row)=>sum+floorToInteger(row.turnover),0)-dutyIncome);
  const nobility=floorToInteger(estatePool*10/85),clergy=floorToInteger(estatePool*5/85),burghers=floorToInteger(estatePool*65/85);
  const estateIncomeByName={Корона:dutyIncome,Знать:nobility,Духовенство:clergy,Горожане:burghers,Крестьяне:estatePool-nobility-clergy-burghers};
  return {resources,internalIncome:dutyIncome,estateIncomeByName,totalTurnover:dutyIncome+estatePool};
}
export function calculateTradeZoneForecast(provinces,previousPrices=new Map()){
  const controlled=(provinces||[]).filter(p=>p.kind==='land'&&(p.layers?.states?.name||p.occupation));
  const stateIds=new Map((provinces||[]).filter(p=>p.layers?.states?.name&&p.layers?.states?.id!=null).map(p=>[p.layers.states.name,Number(p.layers.states.id)]));
  const zoneIds=[...new Set(controlled.map(p=>Number(p.layers?.trade?.id)).filter(Number.isFinite))];
  return zoneIds.map(id=>{
    const zone=controlled.filter(p=>Number(p.layers?.trade?.id)===id),states=new Map(),influence=new Map();
    for(const p of zone){
      const owner=p.layers?.states?.name,controller=p.occupation&&p.occupation!==owner?p.occupation:owner;
      if(!controller)continue;
      states.set(controller,(states.get(controller)||0)+(Number(p.population)||0));
      influence.set(controller,(influence.get(controller)||0)+(Number(calculateProvinceEconomy(p,controller).tradeInfluence)||0));
    }
    const resources=(activeConfig.resources||ECONOMY_RESOURCES).filter(r=>r.showInProduction).map(resource=>{
      const production=zone.filter(p=>p.layers?.resources?.name===resource.name).reduce((sum,p)=>{
        const owner=p.layers?.states?.name,controller=p.occupation&&p.occupation!==owner?p.occupation:owner;
        return sum+(controller?Number(calculateProvinceEconomy(p,controller).production)||0:0);
      },0);
      let demand=0;for(const pop of states.values())demand+=floorToInteger(pop/10*resource.consumption);
      const zonePrices=previousPrices.get?.(id)||previousPrices[id]||new Map();
      const previousValue=Number(zonePrices.get?.(resource.name)??zonePrices[resource.name]??resource.value);
      const previousPrice=previousValue>0?previousValue:resource.value;
      const price=calculateTradePrice(resource.value,demand,production,resource.name,previousPrice);
      const turnover=Math.min(production,demand)*price;
      return {resource_name:resource.name,local_supply:production,demand,incoming:0,balance:production-demand,base_price:resource.value,
        dynamic_price:price,price_trend:price>previousPrice?'up':price<previousPrice?'down':'stable',local_turnover:turnover,incoming_turnover:0};
    }).filter(row=>row.local_supply||row.demand);
    const totalInfluence=[...influence.values()].reduce((sum,value)=>sum+value,0),totalTurnover=resources.reduce((sum,row)=>sum+row.local_turnover,0);
    const participants=[...influence].filter(([,value])=>value>0).map(([state_name,value])=>({state_name,state_id:stateIds.get(state_name)??null,influence:value,
      share:totalInfluence?value/totalInfluence:0,local_income:totalInfluence?totalTurnover*value/totalInfluence:0,export_income:0}));
    const name=zone.find(p=>p.layers?.trade?.name)?.layers.trade.name||'Торговая зона '+id;
    return {id,name,resources,participants};
  });
}
