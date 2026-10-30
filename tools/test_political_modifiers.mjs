import assert from 'node:assert/strict';
import {calculateStatePolitics} from '../economy.js';

const province=(id,race)=>({
  id,kind:'land',province_type:'Регион',population:1000,development:100,control:100,
  layers:{states:{id:1,name:'Тест'},races:{id,name:race},religions:{id:1,name:'Правоверие'},resources:{name:'Зерно'}}
});
const provinces=[province(1,'Эльфы'),province(2,'Люди')];
const politics=[
  ...['Знать','Духовенство','Горожане','Крестьяне'].map(group_key=>({group_type:'estate',group_key,status:'Значимое',loyalty:.5})),
  {group_type:'race',group_key:'1',status:'Официальная',loyalty:.5},
  {group_type:'race',group_key:'2',status:'Невмешательство',loyalty:.5},
  {group_type:'religion',group_key:'1',status:'Официальная',loyalty:.5}
];
const baseline=calculateStatePolitics(provinces,politics,'Тест',{permanent_modifiers:[]});
const modifiers=[
  {key:'estate_loyalty',value:.1,source_kind:'authority',scope:'Все сословия'},
  {key:'peasant_influence',value:-.2,source_kind:'economy',scope:'Государство'},
  {key:'other_race_loyalty',value:-.1,source_kind:'race',source:'Эльфы',scope:'Невмешательство / Ассимиляция / Истребление'}
];
const adjusted=calculateStatePolitics(provinces,politics,'Тест',{permanent_modifiers:modifiers});
assert.ok(adjusted.estateLoyalty.Знать>baseline.estateLoyalty.Знать);
assert.ok(adjusted.estateInfluence.Крестьяне<baseline.estateInfluence.Крестьяне);
assert.ok(adjusted.raceLoyalty[2]<baseline.raceLoyalty[2]);
assert.equal(adjusted.raceLoyalty[1],baseline.raceLoyalty[1]);
assert.ok(adjusted.stateStability!==baseline.stateStability);
console.log('Political modifier calculations: OK');
