import fs from 'node:fs';
import assert from 'node:assert/strict';
import {DEFAULT_ECONOMY_CONFIG,DEFAULT_STATE_EFFECTS} from '../economy.js';

// Exercise the real constants renderer without loading the map or a session.
// Every rendered input must preserve its source value when the form is saved.
const source=fs.readFileSync(new URL('../ui.js',import.meta.url),'utf8');
const renderer=source.slice(source.indexOf('function economyConfigMarkup(){'),source.indexOf('function renderEconomyConstants('));
const config={...DEFAULT_ECONOMY_CONFIG,stateEffects:DEFAULT_STATE_EFFECTS};
const render=new Function('economyDraft','getEconomyConfig','group','escape',`${renderer}; return economyConfigMarkup();`);
const html=render(config,()=>config,(title,content)=>`<section>${content}</section>`,value=>String(value));
const result=structuredClone(config),paths=new Set();
for(const [,path,raw] of html.matchAll(/data-economy-path="([^"]+)" value="([^"]+)"/g)){
  assert.ok(!paths.has(path),`Duplicate input: ${path}`);paths.add(path);
  const parts=path.split('.');let target=result;
  for(const key of parts.slice(0,-1)){assert.ok(target[key]!=null,`Unknown form path: ${path}`);target=target[key];}
  const key=parts.at(-1);assert.ok(Object.hasOwn(target,key),`Unknown form field: ${path}`);
  assert.ok(Number.isFinite(Number(raw)),`Invalid input: ${path}`);
  target[key]=Number(raw);
}
assert.deepEqual(result,config,'Opening and saving constants changed the coefficients');
assert.equal([...paths].filter(path=>path.startsWith('stateEffects.')).length,13);
for(const title of ['Население','Управление','Налоги','Преступность'])assert.ok(html.includes(`<h4>${title}</h4>`));
console.log(`Constants form: ${paths.size} valid paths, unchanged round trip and 13 state-effect inputs passed`);
