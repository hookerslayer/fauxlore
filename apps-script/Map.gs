const LAYERS_={race:'races',religion:'religions',state:'states',resource:'resources',trade:'trade',climate:'climate'};
const TYPES_=['Столица','Город','Регион','Колония','Нейтральная'];
const SCALARS_={name:'name',province_type:'province_type',courts:'courts',development:'development',control:'control',terrain_type:'terrain_type',capital:'has_capital_marker',city:'has_city_marker'};
function text_(value,max,nullable){if(value==null&&nullable)return null;if(typeof value!=='string'||value.length>max)fail_(422,'Некорректное текстовое значение');return value.trim()||null;}
function normalize_(field,value){
  if(LAYERS_[field])return text_(value,field==='state'?100:80,true);
  if(!SCALARS_[field])fail_(422,'Неизвестный параметр');
  if(field==='name'){const name=text_(value,120,false);if(!name)fail_(422,'Укажите название');return name;}
  if(field==='province_type'){if(!TYPES_.includes(value))fail_(422,'Неизвестный тип провинции');return value;}
  if(field==='terrain_type'){if(value!==null&&!['forest','marsh'].includes(value))fail_(422,'Неизвестный тип местности');return value;}
  if(field==='capital'||field==='city'){if(typeof value!=='boolean')fail_(422,'Укажите да или нет');return value;}
  if(field==='courts'||field==='development'){if(value===null&&field==='development')return null;const max=field==='courts'?100000000:1000000;if(!Number.isInteger(value)||value<0||value>max)fail_(422,'Укажите целое неотрицательное число');return value;}
  return text_(value,100,true);
}
function category_(db,layer,name,create){
  if(!name)return null;
  let row=db.rows('map_categories').find(r=>r.layer===layer&&r.name.toLowerCase()===name.toLowerCase());
  if(!row&&create){const raw=hash_(name);const color='#'+[0,2,4].map(i=>(75+parseInt(raw.slice(i,i+2),16)%141).toString(16).padStart(2,'0')).join('');row=db.add('map_categories',{layer,id:Math.max(0,...db.rows('map_categories').filter(r=>r.layer===layer).map(r=>r.id))+1,name,color});}
  if(!row)fail_(422,'Неизвестное значение: '+name);return row;
}
function assign_(db,id,layer,name){
  const category=category_(db,layer,name,layer==='states');
  if(!category){db.remove('province_values',r=>r.province_id===id&&r.layer===layer);return;}
  const value=db.rows('province_values').find(r=>r.province_id===id&&r.layer===layer);
  if(value)value.category_id=category.id;else db.add('province_values',{province_id:id,layer,category_id:category.id});
}
const MAP_CACHE_TTL_=60,MAP_CACHE_CHUNK_=18000;
function mapCacheKey_(dataRevision,tileRevision){return 'map:v2:'+String(dataRevision??0)+':'+String(tileRevision??0);}
function readMapCache_(key){
  const cache=CacheService.getScriptCache(),count=Number(cache.get(key+':count'));
  if(!Number.isInteger(count)||count<1||count>500)return null;
  const chunks=[];
  for(let offset=0;offset<count;offset+=100){
    const keys=Array.from({length:Math.min(100,count-offset)},(_,i)=>key+':'+(offset+i));
    const values=cache.getAll(keys);if(keys.some(k=>values[k]==null))return null;
    chunks.push(...keys.map(k=>values[k]));
  }
  try{return JSON.parse(chunks.join(''));}catch{return null;}
}
function writeMapCache_(key,value){
  const cache=CacheService.getScriptCache(),serialized=JSON.stringify(value),count=Math.ceil(serialized.length/MAP_CACHE_CHUNK_);
  if(!count||count>500)return;
  for(let offset=0;offset<count;offset+=100){
    const entries={};for(let i=offset;i<Math.min(count,offset+100);i++)entries[key+':'+i]=serialized.slice(i*MAP_CACHE_CHUNK_,(i+1)*MAP_CACHE_CHUNK_);
    cache.putAll(entries,MAP_CACHE_TTL_);
  }
  cache.put(key+':count',String(count),MAP_CACHE_TTL_);
}
function mapData_(db){
  const region=db.get('region'),tileRevision=db.get('tile_revision'),dataRevision=db.get('data_revision');
  const cacheKey=mapCacheKey_(dataRevision,tileRevision);let cached=null;try{cached=readMapCache_(cacheKey);}catch{}
  if(cached)return cached;
  const inRegion=p=>!Array.isArray(region)||region.length!==4||!Array.isArray(p.bbox)||p.bbox.length!==4||
    (p.bbox[0]<region[2]&&p.bbox[2]>region[0]&&p.bbox[1]<region[3]&&p.bbox[3]>region[1]);
  const categories=db.rows('map_categories').map(clone_),categoryIndex=new Map(categories.map(r=>[r.layer+':'+r.id,r]));
  const provinces=db.rows('provinces').filter(inRegion).map(r=>({...clone_(r),layers:{}})),index=new Map(provinces.map(p=>[p.id,p]));
  for(const value of db.rows('province_values')){const p=index.get(value.province_id),c=categoryIndex.get(value.layer+':'+value.category_id);if(p&&c)p.layers[value.layer]={id:c.id,name:c.name,color:c.color};}
  for(const p of provinces){if(p.kind==='sea'){delete p.layers;for(const key of ['province_type','courts','population','development','taxes','production','warehouse','control','tension','has_capital_marker','has_city_marker'])delete p[key];continue;}
    if(p.control&&p.control!==p.layers.states?.name)p.control_color=categories.find(c=>c.layer==='states'&&c.name===p.control)?.color;}
  const ids=new Set(index.keys());
  const markers=db.rows('map_markers').filter(m=>ids.has(m.province_id)&&['capital','city','fortress','port'].includes(m.type)).map(m=>({...clone_(m),state_name:categoryIndex.get('states:'+m.state_id)?.name||null}));
  const result={provinces:provinces.sort((a,b)=>a.id-b.id),categories,markers,region,calendar:db.get('calendar'),tile_revision:tileRevision,data_revision:dataRevision};
  try{writeMapCache_(cacheKey,result);}catch(error){console.warn('Map cache write failed',error);}
  return result;
}
function provincePayload_(db,id){
  const source=db.rows('provinces').find(p=>p.id===id);if(!source)fail_(404,'Провинция не найдена');
  const p={...clone_(source),layers:{}};
  for(const v of db.rows('province_values').filter(r=>r.province_id===id)){const c=db.rows('map_categories').find(r=>r.layer===v.layer&&r.id===v.category_id);if(c)p.layers[v.layer]={id:c.id,name:c.name,color:c.color};}
  if(p.control&&p.control!==p.layers.states?.name)p.control_color=db.rows('map_categories').find(c=>c.layer==='states'&&c.name===p.control)?.color;
  return p;
}
function editProvince_(db,id,body){
  const p=db.rows('provinces').find(r=>r.id===id);if(!p)fail_(404,'Провинция не найдена');if(p.kind!=='land')fail_(422,'Редактировать можно только сухопутные провинции');
  const changes=Object.fromEntries(Object.entries(body).map(([k,v])=>[k,normalize_(k,v)]));if(!Object.keys(changes).length)fail_(422,'Нет изменений');
  for(const [key,value] of Object.entries(changes)){
    if(LAYERS_[key])assign_(db,id,LAYERS_[key],value);
    else if(key==='control')p.control=value?category_(db,'states',value,true).name:null;
    else p[SCALARS_[key]]=value;
  }
  if('courts' in changes)p.population=p.courts*4;
  const state=db.rows('province_values').some(r=>r.province_id===id&&r.layer==='states');
  if(p.has_capital_marker)p.province_type='Столица';else if(p.has_city_marker)p.province_type='Город';else if(!('province_type' in changes)&&['capital','city','state'].some(k=>k in changes))p.province_type=state?'Регион':'Нейтральная';
  return p;
}
function createMarker_(db,body){
  if(Object.keys(body).some(k=>!['province_id','x','y','type','name','state_id'].includes(k)))fail_(422,'Неизвестное поле маркера');
  const p=db.rows('provinces').find(p=>p.id===body.province_id);if(!p)fail_(404,'Провинция не найдена');
  const name=text_(body.name,120,false);if(!name||!['capital','city','fortress','port'].includes(body.type))fail_(422,'Некорректный маркер');
  if(!Number.isFinite(body.x)||!Number.isFinite(body.y)||body.x<p.bbox[0]||body.x>=p.bbox[2]||body.y<p.bbox[1]||body.y>=p.bbox[3])fail_(422,'Точка не совпадает с выбранной провинцией');
  const stateId=body.state_id??db.rows('province_values').find(r=>r.province_id===p.id&&r.layer==='states')?.category_id??null;
  const state=stateId===null?null:db.rows('map_categories').find(c=>c.layer==='states'&&c.id===stateId);if(stateId!==null&&!state)fail_(422,'Неизвестное государство');
  const marker=db.add('map_markers',{id:db.nextId('map_markers'),province_id:p.id,x:body.x,y:body.y,type:body.type,name,state_layer:'states',state_id:stateId,description:null,created_at:now_()});return {...clone_(marker),state_name:state?.name||null};
}
function bulk_(db,body,apply){
  if(!Array.isArray(body.rules)||!body.rules.length||body.rules.length>50)fail_(422,'Нужно от 1 до 50 правил');
  const rules=body.rules.map(r=>({...r,condition_value:normalize_(r.condition_field,r.condition_value??null),target_value:normalize_(r.target_field,r.target_value??null)}));
  for(const r of rules){if(r.target_field==='name')fail_(422,'Массовое переименование отключено');for(const side of ['condition','target']){const field=r[side+'_field'],value=r[side+'_value'];if(LAYERS_[field]&&value&&!(side==='target'&&field==='state'))category_(db,LAYERS_[field],value,false);}}
  const bounds=db.get('region'),merged=new Map(),conflicts=new Set(),counts=rules.map(()=>0);
  const layers=new Map();for(const v of db.rows('province_values')){if(!layers.has(v.province_id))layers.set(v.province_id,{});layers.get(v.province_id)[v.layer]=v.category_id;}
  const categoryNames=new Map(db.rows('map_categories').map(c=>[c.layer+':'+c.id,c.name.toLowerCase()]));
  for(const p of db.rows('provinces')){
    if(p.kind!=='land'||p.center[0]<bounds[0]||p.center[0]>=bounds[2]||p.center[1]<bounds[1]||p.center[1]>=bounds[3])continue;
    rules.forEach((r,i)=>{const layer=LAYERS_[r.condition_field],raw=layer?categoryNames.get(layer+':'+layers.get(p.id)?.[layer])??null:p[SCALARS_[r.condition_field]]??null;
      const expected=typeof r.condition_value==='string'?r.condition_value.toLowerCase():r.condition_value;
      const actual=typeof raw==='string'?raw.toLowerCase():raw;
      if(actual!==expected)return;counts[i]++;const changes=merged.get(p.id)||{};
      if(r.target_field in changes&&changes[r.target_field]!==r.target_value)conflicts.add(p.id);else changes[r.target_field]=r.target_value;merged.set(p.id,changes);
    });
  }
  if(!apply)return {rule_counts:counts,total:merged.size,conflict_count:conflicts.size,conflict_examples:[...conflicts].slice(0,10)};
  if(conflicts.size)fail_(409,'Правила пересекаются и задают разные значения одному параметру');
  for(const [id,changes] of merged)editProvince_(db,id,changes);
  return {updated_count:merged.size,rule_counts:counts};
}
