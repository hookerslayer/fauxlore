// Optional operator-generated snapshot; never commit live game data.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {calculateStatePolitics,calculateProvinceEconomy,calculateProvinceValue,setEconomyConfig} from '../economy.js';
const data=JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
setEconomyConfig(data.config);
for(const state of data.states){
  const metrics=state.indicators;
  const provinces=data.provinces;
  const politics=calculateStatePolitics(provinces,data.politics.filter(row=>row.state_id===state.id),state.name,metrics);
  assert.ok(Math.abs(politics.stateStability-metrics.stability)<1e-10,`Stability mismatch: ${state.id}: ${politics.stateStability} / ${metrics.stability}`);
  const owned=provinces.filter(p=>p.kind==='land'&&p.layers?.states?.id===state.id);
  const population=owned.reduce((sum,p)=>sum+p.population,0);
  const urban=owned.reduce((sum,p)=>sum+p.population*({Столичная:.35,Городская:.2}[p.province_type]||0),0);
  assert.equal(metrics.population,population);
  assert.ok(Math.abs(metrics.urban_population-urban)<1e-8);
  assert.ok(Math.abs(metrics.rural_population-(population-urban))<1e-8);
  assert.equal(metrics.missing_development_count,owned.filter(p=>p.development==null).length);
  const known=owned.filter(p=>p.development!=null);
  assert.equal(metrics.total_development,known.length?known.reduce((sum,p)=>sum+p.development,0):owned.length?null:0);
  if(metrics.urbanization_growth_multiplier!=null){
    const growth=owned.map(p=>calculateProvinceEconomy({...p,layers:{...p.layers,states:{...p.layers.states,urbanization_growth_multiplier:metrics.urbanization_growth_multiplier}}},state.name).populationGrowth);
    assert.equal(metrics.population_growth,growth.includes(null)?null:growth.reduce((sum,value)=>sum+value,0));
  }
  const relevant=provinces.filter(p=>p.layers?.states?.id===state.id||p.occupation===state.name);
  for(const p of relevant)if(state.province_values)assert.equal(calculateProvinceValue(p,state.name),state.province_values[p.id],`Province value mismatch: ${p.id}, state ${state.id}`);
  if(metrics.recruit_growth!=null){
    assert.equal(metrics.recruit_growth,relevant.reduce((sum,p)=>sum+calculateProvinceEconomy(p,state.name).recruitGrowth,0));
    assert.equal(metrics.recruit_limit,relevant.reduce((sum,p)=>sum+calculateProvinceEconomy(p,state.name).recruitLimit,0));
  }
}
console.log(`Server/client indicators agree for ${data.states.length} states`);
