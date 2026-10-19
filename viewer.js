import {initUI,hydrateUI,api,settings,LAYERS,isAdminEditing,isAdminPainting,canRenameProvince} from './ui.js';
import {distance,polygonArea,simplePolygon,niceLength} from './map-tools.js';
// PostgreSQL metadata + tiled WebGL geometry, no full CPU pixel copy.
const $ = id => document.getElementById(id);
const html = value => String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const canvas = $('map'), labels = $('labels'), ctx = labels.getContext('2d');
const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, preserveDrawingBuffer: false });
const view = { x: 0, y: 0, scale: 1, min: 0.01, max: 12 };
let width = 10000, height = 10000, tileSize = 2048, columns = 5, rows = 5;
let ready = false, showIds = false, selected = 0, provinces = new Map(), categoryList=[], provinceAdjacency={}, frame = 0, adminPaint=null;
let program, texture, tileSlotsTexture, pickFramebuffer, loc, statusTimer;
let cacheSlots = 25, tileCache = new Map(), tileLoading = new Map(), tileUse = 0;
let region = [0, 0, 10000, 10000]; // min x/y inclusive, max x/y exclusive
let regionSlots = 25;
let colorsTexture,controlColorsTexture,activeSettings=settings,toolMode='',toolPoints=[],areaClosed=false,lastPoint=null;
const thematicComponents=new Map();
const status = (text, timeout = 0) => {
  clearTimeout(statusTimer); $('status').textContent = text;
  if (timeout) statusTimer = setTimeout(() => { $('status').textContent = ''; }, timeout);
};
function schedule() { if (!frame) frame = requestAnimationFrame(draw); }
initUI(status);
function compile(type, source) {
  const shader = gl.createShader(type); gl.shaderSource(shader, source); gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
  return shader;
}
function setupGL() {
  const vertex = compile(gl.VERTEX_SHADER, `#version 300 es
  void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.-1.,0.,1.);}`);
  const fragment = compile(gl.FRAGMENT_SHADER, `#version 300 es
  precision highp float;
  precision highp int;
  precision highp sampler2DArray;
  uniform sampler2DArray uIds;
  uniform sampler2D uTileSlots;
  uniform sampler2D uTypes;
  uniform sampler2D uColors;
  uniform sampler2D uControlColors;
  uniform vec2 uViewport,uOffset,uMapSize,uPickPoint;
  uniform vec4 uRegion;
  uniform float uScale,uDpr;
  uniform int uTileSize,uColumns,uSelected;
  uniform bool uPick,uShowControl;
  out vec4 color;
  ivec4 bytesAt(ivec2 p){
    if(any(lessThan(p,ivec2(0)))||any(greaterThanEqual(p,ivec2(uMapSize))))return ivec4(0);
    ivec2 tile=p/uTileSize;
    int slot=int(round(texelFetch(uTileSlots,tile,0).r*255.))-1;
    if(slot<0)return ivec4(0);
    return ivec4(round(texelFetch(uIds,ivec3(p%uTileSize,slot),0)*255.));
  }
  int idAt(ivec2 p){ivec4 b=bytesAt(p);return (b.r<<16)|(b.g<<8)|b.b;}
  int kindAt(ivec2 p){
    int id=idAt(p);
    if(id==0)return 0;
    int kind=int(round(texelFetch(uTypes,ivec2(id%256,id/256),0).r*255.));
    return kind==3?2:kind;
  }
  void main(){
    vec2 screen=vec2(gl_FragCoord.x,uViewport.y-gl_FragCoord.y)/uDpr;
    ivec2 p=ivec2(floor(uPick?uPickPoint:(screen-uOffset)/uScale));
    if(any(lessThan(vec2(p),uRegion.xy))||any(greaterThanEqual(vec2(p),uRegion.zw))){
      color=uPick?vec4(0.,0.,0.,1.):vec4(.063,.063,.063,1.);return;
    }
    ivec4 bytes=bytesAt(p); int id=(bytes.r<<16)|(bytes.g<<8)|bytes.b;
    if(uPick){color=vec4(vec3(bytes.rgb)/255.,1.);return;}
    if(id==0){color=vec4(.063,.063,.063,1.);return;}
    int kind=kindAt(p);
    // Lakes keep their own ID/type but use the same fill as rivers.
    int rawKind=int(round(texelFetch(uTypes,ivec2(id%256,id/256),0).r*255.));
    const vec3 riverColor=vec3(31./255.,135./255.,173./255.);
    vec3 base=kind==1?vec3(1.,.905882,.839216):rawKind==3?riverColor:vec3(.282353,.388235,.439216);
    vec4 thematic=texelFetch(uColors,ivec2(id%256,id/256),0);
    if(thematic.a>.5&&rawKind!=3)base=thematic.rgb;

    // Multiply at 60% opacity. Packed darkness already includes source alpha;
    // transparent/white relief is neutral. Sampling stays in map coordinates.
    float reliefDarkness=float(bytes.a&127)/127.;
    if(rawKind!=3)base*=1.-.4*reliefDarkness;

    // Selection colors are composited at 50% opacity over the standard fill.
    if(id==uSelected){
      vec3 selectedFill=kind==1?vec3(1.,.94902,.55):vec3(.55,.82,.92);
      base=mix(base,selectedFill,.5);
    }

    vec4 control=texelFetch(uControlColors,ivec2(id%256,id/256),0);
    if(uShowControl&&control.a>.5&&mod(float(p.x+p.y),12.)<2.)base=mix(base,control.rgb,.92);

    // Rivers are packed into the alpha channel of the same nearest-filtered
    // map texture, keeping them pixelated and avoiding a second canvas pass.
    // Sample only the original map texel: river width stays in map units
    // and scales with the terrain, without zoom-dependent dilation.
    bool river=kind==1&&(bytes.a&128)!=0;
    if(river)base=riverColor;

    // Measure the stroke in screen pixels, using the fractional position
    // inside the source texel so it stays fixed even when zoomed in.
    int lineStep=max(1,int(ceil(.75/uScale)));
    bool edge=idAt(p+ivec2(lineStep,0))!=id||idAt(p+ivec2(0,lineStep))!=id;
    int borderStep=max(1,int(ceil(3./uScale)));
    bool coastEdge=kind!=0&&(
      kindAt(p+ivec2(borderStep,0))!=kind&&kindAt(p+ivec2(borderStep,0))!=0||
      kindAt(p-ivec2(borderStep,0))!=kind&&kindAt(p-ivec2(borderStep,0))!=0||
      kindAt(p+ivec2(0,borderStep))!=kind&&kindAt(p+ivec2(0,borderStep))!=0||
      kindAt(p-ivec2(0,borderStep))!=kind&&kindAt(p-ivec2(0,borderStep))!=0);
    if(coastEdge)base=kind==1?vec3(0.):vec3(.055,.18,.26);
    else if(edge)base=kind==1?vec3(0.):vec3(.055,.18,.26);
    color=vec4(base,1.);
  }`);
  program = gl.createProgram(); gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  gl.deleteShader(vertex); gl.deleteShader(fragment); gl.useProgram(program);
  loc = Object.fromEntries(['Ids','Types','Colors','ControlColors','TileSlots','Region','Viewport','Offset','MapSize','PickPoint','Scale','Dpr','TileSize','Columns','Selected','Pick','ShowControl'].map(k => [k, gl.getUniformLocation(program, `u${k}`)]));
  gl.uniform4f(loc.Region,...region);
  gl.uniform1i(loc.Ids, 0); gl.uniform1i(loc.Types, 1); gl.uniform1i(loc.TileSlots, 2);
  gl.uniform1i(loc.Colors,4);
  gl.uniform1i(loc.ControlColors,5);
  gl.uniform2f(loc.MapSize, width, height); gl.uniform1i(loc.TileSize, tileSize); gl.uniform1i(loc.Columns, columns);
  const maxId = Math.max(...provinces.keys());
  const typeRows = Math.ceil((maxId+1)/256), types = new Uint8Array(256*typeRows);
  for (const p of provinces.values()) types[p.id] = {land:1,sea:2,lake:3}[p.kind];
  gl.activeTexture(gl.TEXTURE1);
  const typeTexture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, typeTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, 256, typeRows, 0, gl.RED, gl.UNSIGNED_BYTE, types);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
  texture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);
  gl.texStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.RGBA8, tileSize, tileSize, cacheSlots);
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  // Initialize every texel where the browser exposes clearTexImage. Some
  // WebGL2 implementations omit this optional entry point; partial uploads
  // still work there and untouched padding remains the background ID (0).
  if (typeof gl.clearTexImage === 'function') {
    gl.clearTexImage(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 0, 0]));
  }
  gl.activeTexture(gl.TEXTURE2);
  tileSlotsTexture=gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D,tileSlotsTexture);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.R8,columns,rows,0,gl.RED,gl.UNSIGNED_BYTE,new Uint8Array(columns*rows));
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  // Keep the picking target off TEXTURE0 and TEXTURE2, which hold the map and tile-slot lookup.
  gl.activeTexture(gl.TEXTURE3);
  const pickTexture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, pickTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  pickFramebuffer = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, pickFramebuffer);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, pickTexture, 0);
  if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) throw new Error('Не удалось подготовить выбор провинций');
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);
  gl.disable(gl.DITHER); // Exact byte values for picking, including low province IDs.
  colorsTexture=gl.createTexture(); controlColorsTexture=gl.createTexture(); updateLayerColors();
}
function updateLayerColors(){
  if(!colorsTexture)return;
  const maxId=Math.max(...provinces.keys()),height=Math.ceil((maxId+1)/256),colors=new Uint8Array(256*height*4);
  const controls=new Uint8Array(256*height*4);
  const layer=activeSettings.layer;
  gl.useProgram(program);gl.uniform1i(loc.ShowControl,layer==='states'?1:0);
  const numeric=p=>layer==='population'?(p.population==null?null:Number(p.population)/p.area):(p.development==null?null:Number(p.development));
  const numbers=['population','development'].includes(layer)?[...provinces.values()].map(numeric).filter(v=>v!==null):[];
  const min=numbers.length?Math.min(...numbers):0,max=numbers.length?Math.max(...numbers):0;
  for(const p of provinces.values()){
    let rgb;
    const category=p.layers?.[layer];
    if(category&&/^#[0-9a-f]{6}$/i.test(category.color))rgb=category.color.slice(1).match(/../g).map(x=>parseInt(x,16));
    else if(numbers.length&&numeric(p)!==null){const t=max===min?.5:(numeric(p)-min)/(max-min);rgb=[Math.round(55+177*t),Math.round(65+133*t),Math.round(62+41*t)];}
    if(rgb)colors.set([...rgb,255],p.id*4);
    if(p.control_color&&p.control&&p.control!==p.layers?.states?.name){const controlRgb=p.control_color.slice(1).match(/../g).map(x=>parseInt(x,16));controls.set([...controlRgb,255],p.id*4);}
  }
  gl.activeTexture(gl.TEXTURE4);gl.bindTexture(gl.TEXTURE_2D,colorsTexture);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,256,height,0,gl.RGBA,gl.UNSIGNED_BYTE,colors);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  gl.activeTexture(gl.TEXTURE5);gl.bindTexture(gl.TEXTURE_2D,controlColorsTexture);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,256,height,0,gl.RGBA,gl.UNSIGNED_BYTE,controls);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
}
function uniforms() {
  gl.useProgram(program); gl.uniform2f(loc.Viewport, canvas.width, canvas.height);
  gl.uniform2f(loc.Offset, view.x, view.y); gl.uniform1f(loc.Scale, view.scale);
  gl.uniform1f(loc.Dpr, canvas.width/innerWidth); gl.uniform1i(loc.Selected, selected);
}
function resetTileCache(nextSlots) {
  cacheSlots=nextSlots; tileCache.clear(); tileLoading.clear(); tileUse=0;
  gl.activeTexture(gl.TEXTURE0); if(texture)gl.deleteTexture(texture); texture=gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D_ARRAY,texture);
  gl.texStorage3D(gl.TEXTURE_2D_ARRAY,1,gl.RGBA8,tileSize,tileSize,cacheSlots); gl.texParameteri(gl.TEXTURE_2D_ARRAY,gl.TEXTURE_MIN_FILTER,gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D_ARRAY,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  if(typeof gl.clearTexImage==='function')gl.clearTexImage(gl.TEXTURE_2D_ARRAY,0,gl.RGBA,gl.UNSIGNED_BYTE,new Uint8Array([0,0,0,0]));
  gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D,tileSlotsTexture); gl.texSubImage2D(gl.TEXTURE_2D,0,0,0,columns,rows,gl.RED,gl.UNSIGNED_BYTE,new Uint8Array(columns*rows)); gl.activeTexture(gl.TEXTURE0);
}
function tileRange(){
  // Keep the cache sized to the actual viewport. A one-tile preload margin
  // can exceed the compact zoomed-in cache and evict tiles that are still
  // visible, producing rectangular gaps while the camera is moving.
  const worldLeft=-view.x/view.scale, worldTop=-view.y/view.scale;
  const worldRight=(innerWidth-view.x)/view.scale, worldBottom=(innerHeight-view.y)/view.scale;
  const left=Math.max(Math.floor(region[0]/tileSize),Math.floor(worldLeft/tileSize)), top=Math.max(Math.floor(region[1]/tileSize),Math.floor(worldTop/tileSize));
  const right=Math.min(Math.ceil(region[2]/tileSize)-1,Math.ceil(worldRight/tileSize)-1), bottom=Math.min(Math.ceil(region[3]/tileSize)-1,Math.ceil(worldBottom/tileSize)-1);
  const result=[]; for(let y=top;y<=bottom;y++)for(let x=left;x<=right;x++)result.push([x,y]); return result;
}
function tileSlotFor(key,visible){
  const current=tileCache.get(key); if(current){current.last=++tileUse;return current.slot;}
  let slot=-1; for(let i=0;i<cacheSlots;i++){if(![...tileCache.values()].some(item=>item.slot===i)&&![...tileLoading.values()].some(value=>value===i)){slot=i;break;}}
  if(slot<0){const candidates=[...tileCache.entries()].filter(([k])=>!visible.has(k)).sort((a,b)=>a[1].last-b[1].last);if(!candidates.length)return-1;const[oldKey,old]=candidates[0];tileCache.delete(oldKey);clearTileSlot(oldKey,old.slot);slot=old.slot;}
  tileCache.set(key,{slot,last:++tileUse}); return slot;
}
function clearTileSlot(key,slot){const[x,y]=key.split(',').map(Number);gl.activeTexture(gl.TEXTURE2);gl.bindTexture(gl.TEXTURE_2D,tileSlotsTexture);gl.texSubImage2D(gl.TEXTURE_2D,0,x,y,1,1,gl.RED,gl.UNSIGNED_BYTE,new Uint8Array([0]));gl.activeTexture(gl.TEXTURE0);}
async function loadTile(tx,ty,slot){const key=`${tx},${ty}`;tileLoading.set(key,slot);try{const response=await fetch(`map-data/tiles/${key.replace(',', '_')}.png`);if(!response.ok)throw new Error(`Не найден тайл ${key}`);const bitmap=await createImageBitmap(await response.blob(),{premultiplyAlpha:'none',colorSpaceConversion:'none'});gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D_ARRAY,texture);gl.texSubImage3D(gl.TEXTURE_2D_ARRAY,0,0,0,slot,bitmap.width,bitmap.height,1,gl.RGBA,gl.UNSIGNED_BYTE,bitmap);bitmap.close();const current=tileCache.get(key);if(current&&current.slot===slot){gl.activeTexture(gl.TEXTURE2);gl.bindTexture(gl.TEXTURE_2D,tileSlotsTexture);gl.texSubImage2D(gl.TEXTURE_2D,0,tx,ty,1,1,gl.RED,gl.UNSIGNED_BYTE,new Uint8Array([slot+1]));gl.activeTexture(gl.TEXTURE0);}}catch(error){console.warn(error)}finally{if(tileLoading.get(key)===slot)tileLoading.delete(key);schedule();}}
function ensureVisibleTiles(){const visible=new Set(tileRange().map(([x,y])=>`${x},${y}`));for(const key of visible){const [tx,ty]=key.split(',').map(Number);const slot=tileSlotFor(key,visible);if(slot<0||tileLoading.has(key))continue;if(!tileCache.get(key)?.loaded){tileCache.get(key).loaded=true;loadTile(tx,ty,slot);}}}
function updateTileCapacity(){const next=Math.min(regionSlots,view.scale>view.min*1.8?12:25);if(next!==cacheSlots)resetTileCache(next);}
function draw() {
  frame = 0; if (!ready) return;
  updateTileCapacity(); ensureVisibleTiles();
  gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0,0,canvas.width,canvas.height);
  uniforms(); gl.uniform1i(loc.Pick, 0); gl.drawArrays(gl.TRIANGLES,0,3);
  drawLabels(); drawMeasurements(); updateScale();
}
function getThematicComponents(layer){
  if(thematicComponents.has(layer))return thematicComponents.get(layer);
  const visited=new Set(),components=[];
  for(const start of provinces.values()){
    const category=start.layers?.[layer];if(!category||visited.has(start.id))continue;
    const members=[],queue=[start];visited.add(start.id);
    for(let cursor=0;cursor<queue.length;cursor++){
      const province=queue[cursor];members.push(province);
      for(const neighborId of provinceAdjacency[province.id]||[]){
        const neighbor=provinces.get(neighborId);
        if(neighbor&&!visited.has(neighborId)&&neighbor.layers?.[layer]?.id===category.id){visited.add(neighborId);queue.push(neighbor);}
      }
    }
    const area=members.reduce((sum,p)=>sum+p.area,0);
    const center=members.reduce((sum,p)=>[sum[0]+p.center[0]*p.area,sum[1]+p.center[1]*p.area],[0,0]).map(value=>value/area);
    components.push({name:category.name,members,area,center});
  }
  components.sort((a,b)=>b.area-a.area);thematicComponents.set(layer,components);return components;
}
function drawLabels() {
  const dpr = labels.width/innerWidth;
  ctx.setTransform(dpr,0,0,dpr,0,0); ctx.clearRect(0,0,innerWidth,innerHeight);
  const showMarkers=activeSettings.markers?.capital||activeSettings.markers?.city;
  if (!showIds&&!Object.values(activeSettings.information).some(Boolean)&&!showMarkers) return;
  ctx.font = '600 11px system-ui'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.lineWidth = 3; ctx.strokeStyle = '#13232ddd'; ctx.fillStyle = '#fff9e8';
  const occupied = new Set(),labelRects=[];
  const ordered = [...provinces.values()].sort((a,b) => (b.id===selected)-(a.id===selected) || b.area-a.area);
  for (const p of ordered) {
    if(p.center[0]<region[0]||p.center[1]<region[1]||p.center[0]>=region[2]||p.center[1]>=region[3])continue;
    const x = p.center[0]*view.scale+view.x, y = p.center[1]*view.scale+view.y;
    if (x < -30 || y < -10 || x > innerWidth+30 || y > innerHeight+10) continue;
    const key = `${Math.floor(x/42)},${Math.floor(y/18)}`;
    if(activeSettings.markers?.capital&&p.has_capital_marker){ctx.font='700 17px system-ui';ctx.fillStyle='#f3d778';ctx.strokeText('★',x,y-12);ctx.fillText('★',x,y-12);}
    else if(activeSettings.markers?.city&&p.has_city_marker){ctx.font='700 15px system-ui';ctx.fillStyle='#f3d778';ctx.strokeText('●',x,y-11);ctx.fillText('●',x,y-11);}
    if (occupied.has(key) && p.id !== selected) continue;
    const hasVisibleMarker=activeSettings.markers?.capital&&p.has_capital_marker||activeSettings.markers?.city&&p.has_city_marker;
    const text=showIds?String(p.id):activeSettings.information.provinces||hasVisibleMarker&&activeSettings.markers?.names?p.name:'';
    if(!text)continue;
    occupied.add(key);const textWidth=ctx.measureText(text).width;labelRects.push({left:x-textWidth/2-3,right:x+textWidth/2+3,top:y-9,bottom:y+9});ctx.strokeText(text,x,y); ctx.fillText(text,x,y);
  }
  for(const layer of ['states','races','religions','resources','trade']){
    if(!activeSettings.information[layer])continue;
    const components=getThematicComponents(layer);ctx.font='600 13px system-ui';ctx.fillStyle='#e7c667';
    for(const component of components){
      const candidates=[...component.members].sort((a,b)=>Math.hypot(a.center[0]-component.center[0],a.center[1]-component.center[1])-Math.hypot(b.center[0]-component.center[0],b.center[1]-component.center[1]));
      const width=ctx.measureText(component.name).width;
      for(const province of candidates){
        const [wx,wy]=province.center;if(wx<region[0]||wy<region[1]||wx>=region[2]||wy>=region[3])continue;
        const x=wx*view.scale+view.x,y=wy*view.scale+view.y;if(x<-width/2||x>innerWidth+width/2||y<10||y>innerHeight-10)continue;
        const key=`${Math.floor(x/42)},${Math.floor(y/18)}`;if(occupied.has(key))continue;
        const rect={left:x-width/2-4,right:x+width/2+4,top:y-10,bottom:y+10};
        if(labelRects.some(other=>rect.left<other.right+4&&rect.right>other.left-4&&rect.top<other.bottom+4&&rect.bottom>other.top-4))continue;
        occupied.add(key);labelRects.push(rect);ctx.strokeText(component.name,x,y);ctx.fillText(component.name,x,y);break;
      }
    }
  }
}
function updateScale(){
  const length=niceLength(140/view.scale),pixels=length*view.scale;
  $('scale-distance').textContent=`${length.toLocaleString('ru-RU',{maximumFractionDigits:2})} km`;
  $('scale-area').textContent=`${(length*length).toLocaleString('ru-RU',{maximumFractionDigits:2})} km² ▫`;
  $('scale-area').title='Площадь квадрата со стороной, равной длине полоски';
  $('scale-line').style.width=`${pixels}px`;
}
function toolResult(text){window.dispatchEvent(new CustomEvent('tools:result',{detail:text}));}
function drawMeasurements(){
  if(!toolPoints.length)return;
  ctx.save();ctx.strokeStyle='#e7c667';ctx.fillStyle='#e7c667';ctx.lineWidth=2;ctx.setLineDash([5,4]);ctx.beginPath();
  toolPoints.forEach((p,i)=>{const x=p[0]*view.scale+view.x,y=p[1]*view.scale+view.y;if(i)ctx.lineTo(x,y);else ctx.moveTo(x,y);});
  if(areaClosed){ctx.closePath();ctx.fillStyle='#e7c66730';ctx.fill();}ctx.stroke();ctx.setLineDash([]);
  for(const p of toolPoints){ctx.beginPath();ctx.arc(p[0]*view.scale+view.x,p[1]*view.scale+view.y,4,0,Math.PI*2);ctx.fillStyle='#e7c667';ctx.fill();}ctx.restore();
}
function finishArea(){
  if(toolMode!=='area')return;
  if(!simplePolygon(toolPoints)){status('Нужен контур из трёх и более точек без самопересечений',4000);return;}
  areaClosed=true;toolResult(`Площадь: ${polygonArea(toolPoints).toLocaleString('ru-RU',{maximumFractionDigits:2})} km²`);schedule();
}
function mapClick(x,y){
  const p=[(x-view.x)/view.scale,(y-view.y)/view.scale];
  if(p[0]<region[0]||p[0]>=region[2]||p[1]<region[1]||p[1]>=region[3])return;
  lastPoint=p;
  if(isAdminPainting()&&adminPaint){
    const id=pickProvinceId(x,y),province=provinces.get(id);
    if(!province){status('Нажмите на провинцию',2500);return;}
    if(province.kind!=='land'){status('Морские объекты нельзя редактировать',2500);return;}
    select(id);
    api(`admin/provinces/${id}`,{method:'PATCH',body:JSON.stringify({[adminPaint.field]:adminPaint.value})})
      .then(result=>window.dispatchEvent(new CustomEvent('province:updated',{detail:result})))
      .catch(error=>status(error.message,4000));
    return;
  }
  if(!toolMode){pick(x,y);return;}
  if(toolMode==='coordinates'){toolPoints=[p];toolResult(`X: ${p[0].toFixed(2)} · Y: ${p[1].toFixed(2)}`);}
  if(toolMode==='distance'){
    if(toolPoints.length>=2)toolPoints=[];toolPoints.push(p);
    toolResult(toolPoints.length===2?`Расстояние: ${distance(...toolPoints).toLocaleString('ru-RU',{maximumFractionDigits:2})} km`:'Выберите вторую точку');
  }
  if(toolMode==='area'){
    if(areaClosed){toolPoints=[];areaClosed=false;}
    if(!toolPoints.length||distance(toolPoints.at(-1),p)>1e-6)toolPoints.push(p);
    toolResult(`Точек: ${toolPoints.length}. Нажмите «Завершить».`);
  }
  schedule();
}
function resize() {
  const oldW = canvas.width/(canvas.dataset.dpr || 1), oldH = canvas.height/(canvas.dataset.dpr || 1);
  const dpr = Math.min(devicePixelRatio || 1, 2);
  canvas.width = labels.width = Math.round(innerWidth*dpr); canvas.height = labels.height = Math.round(innerHeight*dpr);
  canvas.dataset.dpr = dpr;
  view.min = Math.min(innerWidth/(region[2]-region[0]),innerHeight/(region[3]-region[1]));
  if (ready) { view.x += (innerWidth-oldW)/2; view.y += (innerHeight-oldH)/2; clampView(); }
  schedule();
}
function clampView() {
  view.scale = Math.max(view.min, Math.min(view.max,view.scale));
  const clampAxis = (v,start,end,screen) => (end-start)*view.scale <= screen
    ? (screen-(start+end)*view.scale)/2
    : Math.max(screen-end*view.scale,Math.min(-start*view.scale,v));
  view.x = clampAxis(view.x,region[0],region[2],innerWidth); view.y = clampAxis(view.y,region[1],region[3],innerHeight);
}
function fit() {
  view.scale = view.min; view.x = (innerWidth-(region[0]+region[2])*view.scale)/2; view.y = (innerHeight-(region[1]+region[3])*view.scale)/2; schedule();
}
function zoom(factor,x=innerWidth/2,y=innerHeight/2) {
  if (!ready) return;
  const next = Math.max(view.min,Math.min(view.max,view.scale*factor));
  const ratio = next/view.scale; view.x = x-(x-view.x)*ratio; view.y = y-(y-view.y)*ratio; view.scale = next;
  clampView(); schedule();
}
function select(id, focus=false) {
  const p = provinces.get(id); if (!p) { status(`Провинция с ID ${id} не найдена в игровой области`,4000); return; }
  selected = id; $('selection').hidden = false;$('selection').classList.toggle('admin-edit',p.kind==='land'&&isAdminEditing()); $('selection-title').textContent = p.name;
  const details=$('selection-details');details.replaceChildren();
  const val=value=>value===null||value===undefined||value===''?'—':value;
  const entries=p.kind==='sea'?[['ID',id],['Название',p.name],['Площадь',`${p.area.toLocaleString('ru-RU')} km²`],['Тип объекта','Море']]:[['ID',id],['Тип объекта',p.kind==='lake'?'Озеро':'Суша'],['Название',p.name],['Раса',p.layers?.races?.name],['Религия',p.layers?.religions?.name],['Государство',p.layers?.states?.name],['Тип провинции',p.province_type],['Дворы',p.courts],['Население',Number(p.population??(Number(p.courts||0)*4)).toLocaleString('ru-RU')],['Ресурс',p.layers?.resources?.name],['Торговая зона',p.layers?.trade?.name],['Развитие',p.development],['Налоги',p.taxes],['Производство',p.production],['Склад',p.warehouse],['Контроль',p.control],['Напряженность',p.tension],['Климат',p.layers?.climate?.name],['Площадь',`${p.area.toLocaleString('ru-RU')} km²`]];
  for(const[label,value]of entries){const div=document.createElement('div');div.className='province-field';const name=document.createElement('span');name.textContent=`${label}: `;const content=document.createElement('strong');content.textContent=val(value);div.append(name,content);details.append(div);}
  if(p.kind==='land'&&isAdminEditing())renderAdminEditor(p,details);
  else if(p.kind==='land'&&canRenameProvince(p.layers?.states?.id))renderNameEditor(p,details);
  if($('province-id'))$('province-id').value = id;
  if (focus) {
    const [bx0,by0,bx1,by1] = p.bbox;
    const [x0,y0,x1,y1] = [Math.max(bx0,region[0]),Math.max(by0,region[1]),Math.min(bx1,region[2]-1),Math.min(by1,region[3]-1)];
    const panelSpace = innerWidth > 600 ? 340 : 128;
    view.scale = Math.max(view.min,Math.min(view.max, (innerWidth-panelSpace)/Math.max(x1-x0+1,40)*.65, innerHeight/Math.max(y1-y0+1,40)*.65));
    view.x = (innerWidth+(innerWidth > 600 ? 290 : 0))/2 - (x0+x1)/2*view.scale;
    view.y = innerHeight/2 - (y0+y1)/2*view.scale;
    clampView();
  }
  schedule();
}

function renderAdminEditor(p,host){
  const form=document.createElement('form');form.id='province-admin-form';form.className='province-editor';
  const categories=categoryList;
  const choice=(name,title,layer)=>`<label class="field"><span>${title}</span><select name="${name}"><option value="">—</option>${categories.filter(c=>c.layer===layer).map(c=>`<option value="${html(c.name)}" ${p.layers?.[layer]?.id===c.id?'selected':''}>${html(c.name)}</option>`).join('')}</select></label>`;
  form.innerHTML=`<div class="editor-grid"><label class="field"><span>Название</span><input name="name" value="${html(p.name)}" maxlength="120" required></label>${choice('race','Раса','races')}${choice('religion','Религия','religions')}<label class="field"><span>Государство</span><input name="state" list="state-options" value="${html(p.layers?.states?.name||'')}" data-original="${html(p.layers?.states?.name||'')}"><datalist id="state-options">${categories.filter(c=>c.layer==='states').map(c=>`<option value="${html(c.name)}">`).join('')}</datalist></label><label class="field"><span>Тип провинции</span><select name="province_type" data-original="${html(p.province_type||'Нейтральная')}">${['Столица','Город','Регион','Колония','Нейтральная'].map(type=>`<option ${p.province_type===type?'selected':''}>${type}</option>`).join('')}</select></label><label class="field"><span>Дворы</span><input name="courts" type="number" min="0" step="1" value="${p.courts??0}"></label>${choice('resource','Ресурс','resources')}${choice('trade','Торговая зона','trade')}<label class="field"><span>Развитие</span><input name="development" type="number" min="0" step="1" value="${p.development??''}"></label><label class="field"><span>Контроль / оккупант</span><input name="control" list="state-options" value="${html(p.control||'')}"></label>${choice('climate','Климат','climate')}<label class="check-row"><span>Маркер: Столица</span><input name="capital" type="checkbox" data-original="${p.has_capital_marker?'true':'false'}" ${p.has_capital_marker?'checked':''}></label><label class="check-row"><span>Маркер: Город</span><input name="city" type="checkbox" data-original="${p.has_city_marker?'true':'false'}" ${p.has_city_marker?'checked':''}></label></div><p class="hint">Население рассчитывается автоматически: дворы × 4. Налоги, производство, склад и напряжённость будут рассчитаны экономической моделью.</p><button class="primary" type="submit">Сохранить изменения</button>`;
  host.append(form);
  form.onsubmit=async event=>{event.preventDefault();const data=new FormData(form),payload={};for(const key of ['name','race','religion','resource','trade','control','climate'])payload[key]=data.get(key)||null;const stateInput=form.elements.state;if(stateInput.value.trim()!==stateInput.dataset.original)payload.state=stateInput.value.trim()||null;const type=form.elements.province_type;if(type.value!==type.dataset.original)payload.province_type=type.value;payload.courts=data.get('courts')===''?0:Number(data.get('courts'));payload.development=data.get('development')===''?null:Number(data.get('development'));for(const key of ['capital','city']){const input=form.elements[key];if(input.checked!==(input.dataset.original==='true'))payload[key]=input.checked;}const button=form.querySelector('button');button.disabled=true;try{const result=await api(`admin/provinces/${p.id}`,{method:'PATCH',body:JSON.stringify(payload)});window.dispatchEvent(new CustomEvent('province:updated',{detail:result}));}catch(error){button.disabled=false;status(error.message,4000);}};
}
function renderNameEditor(p,host){
  const form=document.createElement('form');form.className='province-editor';form.innerHTML=`<label class="field"><span>Название провинции</span><input name="name" maxlength="120" value="${html(p.name)}" required></label><button type="submit">Сохранить название</button>`;host.append(form);
  form.onsubmit=async event=>{event.preventDefault();try{const result=await api(`provinces/${p.id}/name`,{method:'PATCH',body:JSON.stringify({name:new FormData(form).get('name')})});window.dispatchEvent(new CustomEvent('province:renamed',{detail:result}));}catch(error){status(error.message,4000);}};
}
function pickProvinceId(x,y) {
  if (!ready) return;
  uniforms(); gl.bindFramebuffer(gl.FRAMEBUFFER,pickFramebuffer); gl.viewport(0,0,1,1);
  gl.uniform1i(loc.Pick,1); gl.uniform2f(loc.PickPoint,(x-view.x)/view.scale,(y-view.y)/view.scale);
  gl.drawArrays(gl.TRIANGLES,0,3);
  const pixel = new Uint8Array(4); gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
  const id = (pixel[0]<<16)|(pixel[1]<<8)|pixel[2];
  return id;
}
function pick(x,y) {
  const id=pickProvinceId(x,y);
  if (id) select(id); else { selected=0; $('selection').hidden=true; }
  schedule();
}
const pointers = new Map(); let gesture = null, moved = false;
function snapshotGesture() {
  const points=[...pointers.values()];
  if (!points.length) { gesture=null; return; }
  const center = points.length>1 ? {x:(points[0].x+points[1].x)/2,y:(points[0].y+points[1].y)/2} : points[0];
  gesture = { center, x:view.x,y:view.y,scale:view.scale,distance:points.length>1?Math.hypot(points[0].x-points[1].x,points[0].y-points[1].y):0 };
}
canvas.addEventListener('pointerdown',e => {
  if (!ready || (e.pointerType==='mouse' && e.button!==0)) return;
  canvas.setPointerCapture(e.pointerId); pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});
  if(pointers.size===1)moved=false; else moved=true;
  snapshotGesture(); canvas.classList.add('dragging');
});
canvas.addEventListener('pointermove',e => {
  if(!pointers.has(e.pointerId)||!gesture)return;
  pointers.set(e.pointerId,{x:e.clientX,y:e.clientY}); const points=[...pointers.values()];
  const center=points.length>1?{x:(points[0].x+points[1].x)/2,y:(points[0].y+points[1].y)/2}:points[0];
  if(Math.hypot(center.x-gesture.center.x,center.y-gesture.center.y)>4)moved=true;
  const ratio=points.length>1 && gesture.distance>0?Math.hypot(points[0].x-points[1].x,points[0].y-points[1].y)/gesture.distance:1;
  view.scale=Math.max(view.min,Math.min(view.max,gesture.scale*ratio));
  view.x=center.x-(gesture.center.x-gesture.x)*view.scale/gesture.scale;
  view.y=center.y-(gesture.center.y-gesture.y)*view.scale/gesture.scale;
  clampView(); schedule();
});
function endPointer(e) {
  if(!pointers.has(e.pointerId))return;
  const click=!moved&&pointers.size===1&&e.type==='pointerup'; pointers.delete(e.pointerId);
  if(!pointers.size)canvas.classList.remove('dragging');
  snapshotGesture(); if(click)mapClick(e.clientX,e.clientY);
}
canvas.addEventListener('pointerup',endPointer); canvas.addEventListener('pointercancel',endPointer);
canvas.addEventListener('wheel',e=>{ e.preventDefault(); zoom(Math.exp(-e.deltaY*(e.deltaMode===1?.045:.0015)),e.clientX,e.clientY); },{passive:false});
canvas.addEventListener('dblclick',e=>{e.preventDefault();if(toolMode==='area')finishArea();else if(!toolMode)zoom(2,e.clientX,e.clientY);});
window.addEventListener('map:settings',e=>{activeSettings=e.detail;showIds=!!e.detail.showIds;if(ready)updateLayerColors();schedule();});
window.addEventListener('admin:editing',()=>{if(selected)select(selected);});
window.addEventListener('map:admin-paint',e=>{adminPaint=e.detail||null;if(adminPaint)status('Нанесение включено: нажимайте на сухопутные провинции',3000);});
window.addEventListener('province:updated',e=>{const p=e.detail;provinces.set(p.id,{...provinces.get(p.id),...p});thematicComponents.clear();for(const[layer,category]of Object.entries(p.layers||{}))if(!categoryList.some(c=>c.layer===layer&&c.id===category.id))categoryList.push({layer,...category});if(selected===p.id)select(p.id);updateLayerColors();schedule();});
window.addEventListener('map:refresh',async()=>{try{const data=await api('map');categoryList=data.categories;provinces=new Map(data.provinces.map(p=>[p.id,{...p,rgb:p.id}]));provinceAdjacency=data.adjacency||{};thematicComponents.clear();window.dispatchEvent(new CustomEvent('map:refreshed',{detail:data}));if(selected&&!provinces.has(selected))selected=0;if(selected)select(selected);updateLayerColors();schedule();}catch(error){status(error.message,5000);}});
window.addEventListener('province:renamed',e=>{const p=provinces.get(e.detail.id);if(p){p.name=e.detail.name;if(selected===p.id)select(p.id);schedule();}});
window.addEventListener('map:search',e=>{if(ready)select(e.detail,true);});
window.addEventListener('map:tool',e=>{toolMode=e.detail;toolPoints=[];areaClosed=false;canvas.classList.toggle('measuring',!!toolMode);toolResult(toolMode?'Нажмите на карту':'Выберите инструмент');schedule();});
window.addEventListener('map:finish',finishArea);
window.addEventListener('map:undo',()=>{toolPoints.pop();areaClosed=false;toolResult(`Точек: ${toolPoints.length}`);schedule();});
window.addEventListener('map:clear-tool',()=>{toolPoints=[];areaClosed=false;toolResult('Измерение очищено');schedule();});
window.addEventListener('map:coordinate',e=>{const[x,y]=e.detail;if(x<region[0]||x>=region[2]||y<region[1]||y>=region[3]){status('Точка находится вне игровой области',4000);return;}view.scale=Math.max(view.scale,1);view.x=innerWidth/2-x*view.scale;view.y=innerHeight/2-y*view.scale;clampView();schedule();});
window.addEventListener('map:copy-coordinates',async()=>{if(!lastPoint){status('Сначала выберите точку на карте',3000);return;}try{await navigator.clipboard.writeText(lastPoint.map(v=>v.toFixed(2)).join(', '));status('Координаты скопированы',2500);}catch{status('Не удалось скопировать координаты',3000);}});
$('clear-selection').onclick=()=>{selected=0;$('selection').hidden=true;schedule();};
window.addEventListener('resize',resize);
canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();ready=false;status('Графический контекст потерян. Перезагрузите страницу.');});
async function init() {
  if(!gl)throw new Error('Для просмотра карты требуется браузер с WebGL 2.');
  const data=await api('map');region=data.region;categoryList=data.categories;provinceAdjacency=data.adjacency||{};
  if(!Array.isArray(region)||region.length!==4||!region.every(Number.isFinite)||region[0]<0||region[1]<0||region[2]>width||region[3]>height||region[0]>=region[2]||region[1]>=region[3])throw new Error('Некорректные границы игровой области');
  provinces=new Map(data.provinces.map(p=>[p.id,{...p,rgb:p.id}]));
  regionSlots=(Math.ceil(region[2]/tileSize)-Math.floor(region[0]/tileSize))*(Math.ceil(region[3]/tileSize)-Math.floor(region[1]/tileSize));
  cacheSlots=Math.min(25,regionSlots);
  width=10000;height=10000;tileSize=2048;columns=5;rows=5;
  if(gl.getParameter(gl.MAX_TEXTURE_SIZE)<tileSize||gl.getParameter(gl.MAX_ARRAY_TEXTURE_LAYERS)<cacheSlots)throw new Error('Браузер не поддерживает нужный размер тайлов WebGL.');
  setupGL();
  ready=true;resize();fit();
  await hydrateUI(data);
  status('',0);
}
init().catch(error=>{console.error(error);status(error.message);});
