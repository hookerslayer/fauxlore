/* Private spreadsheet storage. Only fxRpc is exposed through google.script.run. */
const JSON_COLUMNS_ = new Set(['center','bbox','production','warehouse','settings','value_json']);
function fail_(status,message){const e=new Error(message);e.status=status;throw e;}
function properties_(){return PropertiesService.getScriptProperties();}
function now_(){return new Date().toISOString();}
function hash_(value){return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,value,Utilities.Charset.UTF_8).map(b=>(b&255).toString(16).padStart(2,'0')).join('');}
function random_(){return Utilities.getUuid().replace(/-/g,'')+Utilities.getUuid().replace(/-/g,'');}
function clone_(row){const result={};for(const key of Object.keys(row))if(!key.startsWith('_'))result[key]=row[key];return result;}
function decode_(key,value){if(value===''||value==null)return null;if(value instanceof Date)return value.toISOString();if(JSON_COLUMNS_.has(key)&&typeof value==='string')return JSON.parse(value);return value;}
function cell_(value){if(value==null)return {};if(typeof value==='object')value=JSON.stringify(value);return {userEnteredValue:typeof value==='number'?{numberValue:value}:typeof value==='boolean'?{boolValue:value}:{stringValue:String(value)}};}
function Store_(){
  const id=properties_().getProperty('DATABASE_SPREADSHEET_ID');
  if(!id)fail_(503,'Не настроен DATABASE_SPREADSHEET_ID');
  this.id=id;this.book=SpreadsheetApp.openById(id);this.tables={};
}
Store_.prototype.table=function(name){
  if(this.tables[name])return this.tables[name];
  const sheet=this.book.getSheetByName(name);if(!sheet)fail_(503,'В базе отсутствует таблица '+name);
  const data=sheet.getDataRange().getValues(),headers=data.shift(),original=new Map(),rows=[];
  data.forEach((values,index)=>{if(values[0]===''||values[0]==null)return;const row={};headers.forEach((key,col)=>row[key]=decode_(key,values[col]));row._row=index+2;rows.push(row);original.set(row._row,JSON.stringify(clone_(row)));});
  const table={sheet,headers,rows,original,next:sheet.getLastRow()+1};this.tables[name]=table;return table;
};
Store_.prototype.rows=function(name){return this.table(name).rows;};
Store_.prototype.add=function(name,value){const t=this.table(name),row={...value,_row:t.next++};t.rows.push(row);return row;};
Store_.prototype.remove=function(name,predicate){const t=this.table(name);t.rows=t.rows.filter(row=>!predicate(row));};
Store_.prototype.nextId=function(name){return Math.max(0,...this.rows(name).map(row=>Number(row.id)||0))+1;};
Store_.prototype.get=function(key){return this.rows('_settings').find(row=>row.key===key)?.value_json;};
Store_.prototype.set=function(key,value){const row=this.rows('_settings').find(row=>row.key===key);if(row)row.value_json=value;else this.add('_settings',{key,value_json:value});};
Store_.prototype.blob=function(reference){
  if(!reference)return null;if(!String(reference).startsWith('@blob:'))fail_(500,'Некорректная ссылка на изображение');
  const key=reference.slice(6),parts=this.rows('_blobs').filter(r=>r.key===key).sort((a,b)=>a.chunk_index-b.chunk_index);
  if(!parts.length)fail_(500,'Отсутствуют данные изображения');return parts.map(r=>r.base64).join('');
};
Store_.prototype.putBlob=function(encoded){
  const key='google:'+random_(),raw=Utilities.base64Decode(encoded),sha=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,raw).map(b=>(b&255).toString(16).padStart(2,'0')).join('');
  for(let index=0;index<encoded.length;index+=30000)this.add('_blobs',{key,chunk_index:index/30000,base64:encoded.slice(index,index+30000),sha256:sha});
  return '@blob:'+key;
};
Store_.prototype.commit=function(){
  const requests=[];
  for(const table of Object.values(this.tables)){
    const present=new Set(table.rows.map(r=>r._row)),changes=[];
    for(const row of table.rows)if(table.original.get(row._row)!==JSON.stringify(clone_(row)))changes.push({row:row._row,values:table.headers.map(key=>cell_(row[key]))});
    for(const row of table.original.keys())if(!present.has(row))changes.push({row,values:table.headers.map(()=>({}))});
    if(!changes.length)continue;
    const last=Math.max(...changes.map(c=>c.row)),sheetId=table.sheet.getSheetId();
    if(last>table.sheet.getMaxRows())requests.push({appendDimension:{sheetId,dimension:'ROWS',length:last-table.sheet.getMaxRows()}});
    changes.sort((a,b)=>a.row-b.row);
    for(let start=0;start<changes.length;){let end=start+1;while(end<changes.length&&changes[end].row===changes[end-1].row+1)end++;
      requests.push({updateCells:{range:{sheetId,startRowIndex:changes[start].row-1,endRowIndex:changes[end-1].row,startColumnIndex:0,endColumnIndex:table.headers.length},rows:changes.slice(start,end).map(c=>({values:c.values})),fields:'userEnteredValue'}});start=end;}
  }
  // One atomic Sheets request, including the command receipt. Never write cells one at a time.
  if(requests.length)Sheets.Spreadsheets.batchUpdate({requests},this.id);
};
