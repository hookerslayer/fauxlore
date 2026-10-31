import assert from 'node:assert/strict';
import {calculateProvinceEconomy} from '../supabase/functions/province-projection/economy.js';

const province={
  kind:'land',province_type:'Регион',population:100000,development:100,control:100,
  trade_status:'Отсутствует',layers:{
    states:{name:'Тест',crime:0,urbanization_growth_multiplier:1},
    races:{name:'Зверолюди'},religions:{name:'Витализм'},resources:{name:'Зерно'}
  }
};
const growth=(race,resource)=>calculateProvinceEconomy({
  ...province,layers:{...province.layers,races:{name:race},resources:{name:resource}}
},'Тест').populationGrowth;
const base=growth('Зверолюди','Зерно');
const livestock=growth('Зверолюди','Животноводство');
assert.ok(Math.abs(livestock/base-1.1)<.002,'Бонус должен применяться один раз');
assert.equal(growth('Дварфы','Зерно'),growth('Дварфы','Животноводство'));
console.log('Livestock population modifier: OK');
