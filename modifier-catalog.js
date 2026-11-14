export const requestedModifiers={
  tax_efficiency:['Эффективность налогообложения','п.п.'],corruption_pp:['Коррупция','п.п.'],crime_pp:['Преступность','п.п.'],
  development_limit_flat:['Лимит развития','ур.'],state_stability_flat:['Стабильность государства','п.п.'],population_growth_pp:['Прирост населения','п.п.'],
  nobility_loyalty:['Лояльность Знати','п.п.'],clergy_loyalty:['Лояльность Духовенства','п.п.'],burgher_loyalty:['Лояльность Горожан','п.п.'],peasant_loyalty:['Лояльность Крестьян','п.п.'],
  nobility_influence_pp:['Влияние Знати','п.п.'],clergy_influence_pp:['Влияние Духовенства','п.п.'],burgher_influence_pp:['Влияние Горожан','п.п.'],peasant_influence_pp:['Влияние Крестьян','п.п.'],
  nobility_stabilization:['Стабилизация Знати','п.п.'],clergy_stabilization:['Стабилизация Духовенства','п.п.'],burgher_stabilization:['Стабилизация Горожан','п.п.'],peasant_stabilization:['Стабилизация Крестьян','п.п.'],
  race_human_loyalty:['Лояльность Людей','п.п.'],race_dwarf_loyalty:['Лояльность Дварфов','п.п.'],race_elf_loyalty:['Лояльность Эльфов','п.п.'],race_halfelf_loyalty:['Лояльность Полуэльфов','п.п.'],race_beast_loyalty:['Лояльность Зверолюдей','п.п.'],
  development:['Постоянное изменение развития','ед./ход'],race_assimilation_turns:['Ассимиляция расы','ход'],religion_assimilation_turns:['Ассимиляция религии','ход'],
  production:['Производство','п.п.'],internal_trade_income:['Внутренняя торговля','п.п.'],trade_zone_income:['Доход от торговой зоны','п.п.'],recruit_growth:['Прирост рекрутов','п.п.'],recruit_limit:['Лимит рекрутов','п.п.'],trade_influence:['Торговое влияние','п.п.'],control_modifier_pp:['КМ','п.п.'],
  loan_nobility_rate:['Процентная ставка займов у Знати','п.п.'],loan_clergy_rate:['Процентная ставка займов у Духовенства','п.п.'],loan_burgher_rate:['Процентная ставка займов у Горожан','п.п.'],loan_peasant_rate:['Процентная ставка займов у Крестьян','п.п.'],
  military_tradition_pp:['Военные традиции','п.п.'],naval_tradition_pp:['Морские традиции','п.п.'],leader_limit_flat:['Лимит полководцев','ед.'],leader_prestige_cost_flat:['Стоимость полководца','ОП'],
  garrison_limit_flat:['Лимит гарнизонов','ед.'],garrison_hire_cost:['Стоимость найма в гарнизон','п.п.'],garrison_upkeep:['Стоимость содержания гарнизонов','п.п.'],fortification_upkeep:['Содержание укреплений','%'],port_upkeep:['Содержание портов','%'],militia_coefficient:['Коэффициент сбора ополчения','коэфф.'],
  mercenary_hire_cost:['Стоимость наемников','%'],mercenary_upkeep:['Содержание наемников','%'],infantry_hire_cost:['Стоимость пехоты','%'],cavalry_hire_cost:['Стоимость кавалерии','%'],siege_hire_cost:['Стоимость осадных орудий','%'],artillery_hire_cost:['Стоимость артиллерии','%'],fleet_hire_cost:['Стоимость флота','%'],infantry_upkeep:['Содержание пехоты','%'],cavalry_upkeep:['Содержание кавалерии','%'],siege_upkeep:['Содержание осадных орудий','%'],artillery_upkeep:['Содержание артиллерии','%'],fleet_upkeep:['Содержание флота','%'],
  // Ранее эти эффекты можно было назначить только через местные события.
  prestige:['Престиж за ход','ОП/ход'],prestige_action_cost:['Стоимость действий за ОП','ОП/действие'],prestige_contract_cost:['Стоимость договора за ОП','ОП/договор'],
  consumption:['Потребление ресурсов','%'],precious_consumption:['Потребление Драгоценных металлов','%'],other_consumption:['Потребление остальных ресурсов','%'],
  land_trade_range:['Длина сухопутного маршрута','провинции'],sea_trade_range:['Длина морского маршрута','провинции'],
  colonization_chance:['Шанс колонизации','п.п.'],colonization_duration:['Срок колонизации','ход'],
  estate_loyalty:['Лояльность сословий','п.п.'],peasant_influence:['Влияние Крестьян','%'],other_race_loyalty:['Лояльность других рас','п.п.'],other_religion_loyalty:['Лояльность других религий','п.п.'],
  militia_nobility:['Мобилизационный потенциал ополчения (Знать)','%'],militia_clergy:['Мобилизационный потенциал ополчения (Духовенство)','%'],militia_potential:['Мобилизационный потенциал ополчения (общий)','%'],
  militia_cog_per_development:['Когги от созыва ополчения',null],
  garrison_limit:['Лимит гарнизона','%'],population_growth:['Прирост населения (базовый)','%'],
  regular_hire_cost:['Стоимость найма регулярной армии','%'],regular_upkeep:['Содержание регулярной армии','%'],
  archer_hire_cost:['Стоимость найма лучников','%'],archer_upkeep:['Содержание лучников','%'],
  crossbow_hire_cost:['Стоимость найма арбалетчиков','%'],crossbow_upkeep:['Содержание арбалетчиков','%'],
  firearms_hire_cost:['Стоимость найма пищальников и артиллерии','%'],firearms_upkeep:['Содержание пищальников и артиллерии','%'],
  ranged_hire_cost:['Стоимость найма лучников, арбалетчиков, пищальников и артиллерии','%'],ranged_upkeep:['Содержание лучников, арбалетчиков, пищальников и артиллерии','%'],
  ship_hire_cost:['Стоимость найма кораблей','%'],ship_upkeep:['Содержание кораблей','%']
};
export function modifierTypes(definitions){
  const types=new Map();
  definitions.forEach((d,index)=>{const label=requestedModifiers[d.key];if(label&&!types.has(d.key))types.set(d.key,{...d,index,effect:label[0],unit:label[1]??d.unit});});
  return [...types.values()].sort((a,b)=>a.effect.localeCompare(b.effect,'ru'));
}

export const resourceModifiers=[
  {id:'turn_treasury_income',label:'Постоянный доход казны, G/ход'},
  {id:'turn_treasury_expense',label:'Постоянный расход казны, G/ход'},
  {id:'once_treasury_income',label:'Разовый доход казны, G'},
  {id:'once_treasury_expense',label:'Разовый расход казны, G'},
  {id:'turn_prestige_income',label:'Постоянный доход Престижа, ОП/ход'},
  {id:'turn_prestige_expense',label:'Постоянный расход Престижа, ОП/ход'},
  {id:'once_prestige_income',label:'Разовый доход Престижа, ОП'},
  {id:'once_prestige_expense',label:'Разовый расход Престижа, ОП'}
];
export const isResourceModifier=id=>/^(once|turn)_(prestige|treasury)_(income|expense)$/.test(id);
export function resourceModifierPayload(id,value){const [timing,resource,direction]=id.split('_');return {timing,resource,value:Math.abs(value)*(direction==='expense'?-1:1)};}

export const instantModifiers=[{id:'instant_population',label:'Население, чел.'},{id:'instant_development',label:'Разовое изменение развития, ур.'}];
export const isInstantModifier=id=>/^instant_(population|development)$/.test(id);
