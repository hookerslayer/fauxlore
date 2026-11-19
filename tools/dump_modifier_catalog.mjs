// Выгружает клиентский каталог Конструктора в JSON для сборки документов.
import fs from 'node:fs';
import {requestedModifiers,resourceModifiers,instantModifiers} from '../modifier-catalog.js';

const modifiers=Object.entries(requestedModifiers).map(([key,[label,unit]])=>({
  key,
  label,
  // У коггов единица зависит от выбранного определения; в документе даём базовую.
  unit:unit??'корабль/100 развития',
}));
const json=JSON.stringify({modifiers,resources:resourceModifiers,instant:instantModifiers},null,2);
if(process.argv[2]) fs.writeFileSync(process.argv[2],json,'utf8'); else console.log(json);
