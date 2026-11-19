// Проверяет целостность статического релиза перед выкладкой.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const dir=process.argv[2];
if(!dir) throw new Error('Usage: node tools/validate_release.mjs <release-dir>');
const root=path.resolve(dir);
const tag=path.basename(root);
const fail=message=>{throw new Error(message)};
const files=new Set();
for(const entry of fs.readdirSync(root,{recursive:true,withFileTypes:true})){
  if(entry.isFile()) files.add(path.relative(root,entry.parentPath?path.join(entry.parentPath,entry.name):entry.name).replaceAll('\\','/'));
}
const js=[...files].filter(name=>name.endsWith('.js'));
for(const name of js){
  const text=fs.readFileSync(path.join(root,name),'utf8');
  for(const match of text.matchAll(/(?:from|import)\s*\(?\s*['"]\.\/([^'"?]+\.js)/g)){
    const imported=match[1];
    const resolved=path.posix.normalize(path.posix.join(path.posix.dirname(name),imported));
    if(!files.has(resolved)) fail(`${name}: отсутствует импорт ${imported}`);
  }
}

const index=fs.readFileSync(path.join(root,'index.html'),'utf8');
for(const match of index.matchAll(/<(?:script|link)[^>]+(?:src|href)="([^"]+)"/g)){
  const asset=match[1].split('?')[0];
  if(asset.startsWith('http')) continue;
  if(!files.has(asset)) fail(`index.html: отсутствует ${asset}`);
}
if(!index.includes(`viewer.js?v=${tag}`)) fail(`index.html: не обновлена версия viewer.js (${tag})`);
if(!index.includes(`viewer.css?v=${tag}`)) fail(`index.html: не обновлена версия viewer.css (${tag})`);
const viewer=fs.readFileSync(path.join(root,'viewer.js'),'utf8');
if(!viewer.includes(`from './ui.js?v=${tag}'`)) fail(`viewer.js: не обновлена версия ui.js (${tag})`);
const ui=fs.readFileSync(path.join(root,'ui.js'),'utf8');
if(!ui.includes("from './wall.js?v=")) fail('ui.js: не найден импорт wall.js');
if(!ui.includes("from './modifier-catalog.js?v=")) fail('ui.js: не найден импорт каталога');
if(!fs.readFileSync(path.join(root,'wall.js'),'utf8').includes("from './modifier-catalog.js?v=")) fail('wall.js: не найден импорт каталога');
if(!fs.readFileSync(path.join(root,'app-config.js'),'utf8').includes("backend: 'vps-postgrest'")) fail('app-config.js: неверный backend');

const catalog=await import(pathToFileURL(path.join(root,'modifier-catalog.js')).href);
const count=Object.keys(catalog.requestedModifiers).length;
if(count!==91) fail(`каталог: ${count} ключей вместо 91`);
if(!catalog.requestedModifiers.prestige) fail('каталог: нет prestige');

for(const forbidden of ['CANDIDATE-NOT-LIVE.txt','.env','supabase/migrations']){
  if(files.has(forbidden)||[...files].some(name=>name.startsWith(forbidden+'/'))) fail(`лишний путь: ${forbidden}`);
}
console.log(`OK: ${root} — ${files.size} файлов, ${js.length} JS, ${count} модификаторов`);
