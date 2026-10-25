import assert from 'node:assert/strict';
import {estatePopulation, estateGrossTax, BASE_ESTATE_TAX_RATES, developmentMultiplier} from '../estate-demography.js';

assert.deepEqual(estatePopulation('Регион', 1000), {Знать:10, Духовенство:20, Горожане:50, Крестьяне:920});
assert.deepEqual(estatePopulation('Городская', 1000), {Знать:20, Духовенство:30, Горожане:300, Крестьяне:650});
assert.deepEqual(estatePopulation('Столичная', 1000), {Знать:30, Духовенство:40, Горожане:380, Крестьяне:550});
assert.equal(Object.values(estatePopulation('Регион', 37)).reduce((sum, count) => sum + count, 0), 37);
assert.equal(estatePopulation('Территориальная', 1000), null);
assert.equal(developmentMultiplier(100), 1);
assert.equal(developmentMultiplier(101), 1.01);
assert.equal(estateGrossTax('Регион', 1000, BASE_ESTATE_TAX_RATES), 1190);
assert.equal(estateGrossTax('Регион', 1000, BASE_ESTATE_TAX_RATES, {development:101}), 1201.9);
assert.equal(estateGrossTax('Регион', 1000, BASE_ESTATE_TAX_RATES, {typeTax:.8, control:50, share:.5}), 238);
console.log('Estate demography and tax model: OK');
