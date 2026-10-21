import assert from 'node:assert/strict';
import {PRINCIPLES,principleConflict,governmentName} from '../state-principles.js';

let valid=0;
for(const authority of PRINCIPLES.authority)
  for(const structure of PRINCIPLES.structure)
    for(const economy of PRINCIPLES.economy)
      for(const military of PRINCIPLES.military){
        const chosen={authority,structure,economy,military,ephemeral:'Мораторий'};
        const name=governmentName(chosen);
        assert.equal(Boolean(name),!principleConflict(chosen));
        if(name)valid++;
      }
assert.equal(valid,455);
assert.equal(governmentName({authority:'Династия',structure:'Ленное право',economy:'Крепостничество',military:'Сословная армия',ephemeral:'Мораторий'}),
  'Рыцарская поместная феодальная монархия');
assert.equal(governmentName({authority:'Магистрат',structure:'Содружество',economy:'Гильдии',military:'Гвардия',ephemeral:'Мораторий'}),
  'Патрицианский торговый вольный союз');
assert.equal(governmentName({authority:'Клир',structure:'Ленное право',economy:'Крепостничество',military:'Гвардия',ephemeral:'Мораторий'}),
  'Гвардейское поместное княжество-епископство');
assert.equal(governmentName({authority:'Магистрат',structure:'Командорство',economy:'Гильдии',military:'Гвардия',ephemeral:'Мораторий'}),
  'Патрицианский торговый подеста');
console.log(`Допустимых сочетаний: ${valid}; формы правления согласованы.`);
