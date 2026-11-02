import assert from 'node:assert/strict';
import {modifierTypes,resourceModifiers,resourceModifierPayload,instantModifiers} from '../modifier-catalog.js';

const source=[
 {key:'crime_pp',effect:'old name',unit:'п.п.',value:0},
 {key:'production',effect:'old name',unit:'%',value:0},
 {key:'production',effect:'duplicate',unit:'%',value:0},
 {key:'colonization_chance',effect:'unrequested',unit:'п.п.',value:0},
 {key:'race_assimilation_turns',effect:'old name',unit:'ход',value:0},
 {key:'military_tradition_pp',effect:'old name',unit:'п.п.',value:0},
];
const types=modifierTypes(source);
assert.equal(types.length,4);
assert.equal(types.find(item=>item.key==='production').index,1);
assert.equal(types.find(item=>item.key==='production').unit,'п.п.');
assert.equal(types.find(item=>item.key==='race_assimilation_turns').effect,'Ассимиляция расы');
assert.equal(types.find(item=>item.key==='military_tradition_pp').effect,'Военные традиции');
assert.equal(resourceModifiers.length,8);
assert.deepEqual(resourceModifierPayload('once_treasury_expense',23),{timing:'once',resource:'treasury',value:-23});
assert.deepEqual(resourceModifierPayload('turn_prestige_income',-4),{timing:'turn',resource:'prestige',value:4});
assert.deepEqual(instantModifiers.map(item=>item.id),['instant_population','instant_development']);
console.log('Modifier catalog, deduplication, units and resource signs: OK');
