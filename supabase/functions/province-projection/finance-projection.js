const estates=['Корона','Знать','Духовенство','Горожане','Крестьяне'];
const floor=value=>Math.floor(Number(value)||0);
const sum=rows=>floor(rows.reduce((total,[,value])=>total+(Number(value)||0),0));

export function buildFinanceProjection({stateId,taxForecast,tradeProjection,agreements,garrisonData,colonyData,taxRates,indicators}){
  const accepted=(agreements?.agreements||[]).filter(item=>item.status==='accepted'&&
    (Number(item.from_state_id)===stateId||Number(item.to_state_id)===stateId));
  const tradeGoldIn=floor(accepted.reduce((total,item)=>total+Number((Number(item.from_state_id)===stateId?
    item.terms?.to_gold:item.terms?.from_gold)||0),0));
  const tradeGoldOut=floor(accepted.reduce((total,item)=>total+Number((Number(item.from_state_id)===stateId?
    item.terms?.from_gold:item.terms?.to_gold)||0),0));
  const sponsorGarrison=Object.fromEntries(estates.map(name=>[name,0]));
  for(const province of garrisonData?.provinces||[]){
    const sponsor=estates.includes(province.sponsor)?province.sponsor:'Корона';
    const troops=(province.units||[]).reduce((total,unit)=>total+Number(unit.quantity)*Number(unit.upkeep)*.4,0);
    const fort=Math.max(0,([0,100,200,300,400][Number(province.fort_level)||0]||0)-(province.free_fort?300:0));
    const walls=Math.max(0,([0,300,500,700][Number(province.wall_level)||0]||0)-(province.free_wall?300:0));
    sponsorGarrison[sponsor]+=troops+fort+walls;
  }
  const sponsoredTotal=estates.slice(1).reduce((total,name)=>total+sponsorGarrison[name],0);
  const upkeep=floor(Math.max(0,Number(taxRates.army_upkeep_forecast||0)-sponsoredTotal));
  const colonyUpkeep=floor((colonyData?.missions||[]).length*1000);
  const zoneIncomeByEstate=tradeProjection.zone_income_by_estate||{};
  const adjustedEstateIncome=tradeProjection.adjusted_estate_income||{};
  const estateBudget=Object.fromEntries(estates.map(name=>{
    const income=floor(Number(taxForecast.buckets?.[name]||0)+Number(zoneIncomeByEstate[name]||0)+
      Number(adjustedEstateIncome[name]||0)+(name==='Корона'?tradeGoldIn:0));
    const expense=name==='Корона'?floor(upkeep+colonyUpkeep+tradeGoldOut):floor(sponsorGarrison[name]);
    return [name,{income,expense,saldo:income-expense}];
  }));
  const treasuryIncomeRows=[['Налоговые поступления',taxForecast.buckets?.['Корона']||0],
    ['Внутренняя торговля · пошлина',tradeProjection.adjusted_internal_income||0],
    ['Торговые зоны',zoneIncomeByEstate['Корона']||0],['Золото по договорам',tradeGoldIn],
    ['Прочие разовые поступления',0]];
  const treasuryExpenseRows=[['Содержание армии',upkeep],['Содержание колоний',colonyUpkeep],
    ['Платежи по торговым договорам',tradeGoldOut],['Погашение займов',0],['Прочие разовые списания',0]];
  const prestigeEffects=(indicators?.permanent_modifiers||[])
    .filter(item=>item.key==='prestige'&&item.scope==='Государство');
  const prestigeIncomeRows=[...prestigeEffects.filter(item=>Number(item.value)>0)
    .map(item=>[`${item.effect} · ${item.source}`,floor(item.value)]),['Династический брак',0]];
  const prestigeExpenseRows=[...prestigeEffects.filter(item=>Number(item.value)<0)
    .map(item=>[`${item.effect} · ${item.source}`,floor(-Number(item.value))]),
    ['Изменение налоговой ставки',0],['Местный брак',0],['Торговые предложения',0],
    ['Назначение наследника',0],['Прочие списания',0]];
  const treasurySaldo=sum(treasuryIncomeRows)-sum(treasuryExpenseRows);
  const prestigeSaldo=sum(prestigeIncomeRows)-sum(prestigeExpenseRows);
  return {trade_gold_in:tradeGoldIn,trade_gold_out:tradeGoldOut,sponsor_garrison:sponsorGarrison,
    upkeep,colony_upkeep:colonyUpkeep,estate_budget:estateBudget,
    current_balances:taxRates.buckets||{},
    treasury_income_rows:treasuryIncomeRows,treasury_expense_rows:treasuryExpenseRows,
    prestige_income_rows:prestigeIncomeRows,prestige_expense_rows:prestigeExpenseRows,
    treasury_saldo:treasurySaldo,prestige_saldo:prestigeSaldo,
    current_treasury:floor(taxRates.buckets?.['Корона']),current_prestige:floor(taxRates.prestige),
    next_treasury:floor(taxRates.buckets?.['Корона'])+treasurySaldo,
    next_prestige:floor(taxRates.prestige)+prestigeSaldo};
}
