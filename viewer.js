// Tiled ID texture: no source artwork, CPU pixel copy, or network dependency.
const $ = id => document.getElementById(id);
const canvas = $('map'), labels = $('labels'), ctx = labels.getContext('2d');
const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, preserveDrawingBuffer: false });
const view = { x: 0, y: 0, scale: 1, min: 0.01, max: 12 };
let width = 10000, height = 10000, tileSize = 2048, columns = 5, rows = 5;
let ready = false, showIds = false, selected = 0, provinces = new Map(), frame = 0;
let program, texture, tileSlotsTexture, pickFramebuffer, loc, statusTimer;
let cacheSlots = 25, tileCache = new Map(), tileLoading = new Map(), tileUse = 0;
let region = [0, 0, 10000, 10000]; // min x/y inclusive, max x/y exclusive
let regionSlots = 25;
const status = (text, timeout = 0) => {
  clearTimeout(statusTimer); $('status').textContent = text;
  if (timeout) statusTimer = setTimeout(() => { $('status').textContent = ''; }, timeout);
};
function schedule() { if (!frame) frame = requestAnimationFrame(draw); }
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
  uniform vec2 uViewport,uOffset,uMapSize,uPickPoint;
  uniform vec4 uRegion;
  uniform float uScale,uDpr;
  uniform int uTileSize,uColumns,uSelected;
  uniform bool uPick;
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
      color=uPick?vec4(0.,0.,0.,1.):vec4(.071,.126,.157,1.);return;
    }
    ivec4 bytes=bytesAt(p); int id=(bytes.r<<16)|(bytes.g<<8)|bytes.b;
    if(uPick){color=vec4(vec3(bytes.rgb)/255.,1.);return;}
    if(id==0){color=vec4(.071,.126,.157,1.);return;}
    int kind=kindAt(p);
    // Uniform province fills: land #ffe7d6, water #486370.
    vec3 base=kind==1?vec3(1.,.905882,.839216):vec3(.282353,.388235,.439216);

    // Multiply at 60% opacity. Packed darkness already includes source alpha;
    // transparent/white relief is neutral. Sampling stays in map coordinates.
    float reliefDarkness=float(bytes.a&127)/127.;
    base*=1.-.4*reliefDarkness;

    // Selection colors are composited at 50% opacity over the standard fill.
    if(id==uSelected){
      vec3 selectedFill=kind==1?vec3(1.,.94902,.55):vec3(.55,.82,.92);
      base=mix(base,selectedFill,.5);
    }

    // Rivers are packed into the alpha channel of the same nearest-filtered
    // map texture, keeping them pixelated and avoiding a second canvas pass.
    // Sample only the original map texel: river width stays in map units
    // and scales with the terrain, without zoom-dependent dilation.
    bool river=kind==1&&(bytes.a&128)!=0;
    if(river)base=vec3(.12,.53,.68);

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
  loc = Object.fromEntries(['Ids','Types','TileSlots','Region','Viewport','Offset','MapSize','PickPoint','Scale','Dpr','TileSize','Columns','Selected','Pick'].map(k => [k, gl.getUniformLocation(program, `u${k}`)]));
  gl.uniform4f(loc.Region,...region);
  gl.uniform1i(loc.Ids, 0); gl.uniform1i(loc.Types, 1); gl.uniform1i(loc.TileSlots, 2);
  gl.uniform2f(loc.MapSize, width, height); gl.uniform1i(loc.TileSize, tileSize); gl.uniform1i(loc.Columns, columns);
  const maxId = Math.max(...provinces.keys());
  const rows = Math.ceil((maxId+1)/256), types = new Uint8Array(256*rows);
  for (const p of provinces.values()) types[p.id] = {land:1,sea:2,lake:3}[p.kind];
  gl.activeTexture(gl.TEXTURE1);
  const typeTexture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, typeTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, 256, rows, 0, gl.RED, gl.UNSIGNED_BYTE, types);
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
  drawLabels(); $('zoom-value').textContent = `${Math.round(view.scale*100)}%`;
}
function drawLabels() {
  const dpr = labels.width/innerWidth;
  ctx.setTransform(dpr,0,0,dpr,0,0); ctx.clearRect(0,0,innerWidth,innerHeight);
  if (!showIds) return;
  ctx.font = '600 11px system-ui'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.lineWidth = 3; ctx.strokeStyle = '#13232ddd'; ctx.fillStyle = '#fff9e8';
  const occupied = new Set();
  const ordered = [...provinces.values()].sort((a,b) => (b.id===selected)-(a.id===selected) || b.area-a.area);
  for (const p of ordered) {
    if(p.center[0]<region[0]||p.center[1]<region[1]||p.center[0]>=region[2]||p.center[1]>=region[3])continue;
    const x = p.center[0]*view.scale+view.x, y = p.center[1]*view.scale+view.y;
    if (x < -30 || y < -10 || x > innerWidth+30 || y > innerHeight+10) continue;
    const key = `${Math.floor(x/42)},${Math.floor(y/18)}`;
    if (occupied.has(key) && p.id !== selected) continue;
    occupied.add(key); ctx.strokeText(p.id,x,y); ctx.fillText(p.id,x,y);
  }
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
  selected = id; $('selection').hidden = false; $('selection-title').textContent = `№ ${id} · ${{land:'Суша',sea:'Море',lake:'Озеро'}[p.kind]}`;
  $('selection-details').textContent = `Площадь: ${p.area.toLocaleString('ru-RU')} пикс.²`;
  $('province-id').value = id;
  if (focus) {
    const [bx0,by0,bx1,by1] = p.bbox;
    const [x0,y0,x1,y1] = [Math.max(bx0,region[0]),Math.max(by0,region[1]),Math.min(bx1,region[2]-1),Math.min(by1,region[3]-1)];
    const panelSpace = innerWidth > 600 ? 340 : 40;
    view.scale = Math.max(view.min,Math.min(view.max, (innerWidth-panelSpace)/Math.max(x1-x0+1,40)*.65, innerHeight/Math.max(y1-y0+1,40)*.65));
    view.x = (innerWidth+(innerWidth > 600 ? 290 : 0))/2 - (x0+x1)/2*view.scale;
    view.y = innerHeight/2 - (y0+y1)/2*view.scale;
    clampView();
  }
  schedule();
}
function pick(x,y) {
  if (!ready) return;
  uniforms(); gl.bindFramebuffer(gl.FRAMEBUFFER,pickFramebuffer); gl.viewport(0,0,1,1);
  gl.uniform1i(loc.Pick,1); gl.uniform2f(loc.PickPoint,(x-view.x)/view.scale,(y-view.y)/view.scale);
  gl.drawArrays(gl.TRIANGLES,0,3);
  const pixel = new Uint8Array(4); gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
  const id = (pixel[0]<<16)|(pixel[1]<<8)|pixel[2];
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
  snapshotGesture(); if(click)pick(e.clientX,e.clientY);
}
canvas.addEventListener('pointerup',endPointer); canvas.addEventListener('pointercancel',endPointer);
canvas.addEventListener('wheel',e=>{ e.preventDefault(); zoom(Math.exp(-e.deltaY*(e.deltaMode===1?.045:.0015)),e.clientX,e.clientY); },{passive:false});
canvas.addEventListener('dblclick',e=>{e.preventDefault();zoom(2,e.clientX,e.clientY);});
$('zoom-in').onclick=()=>zoom(1.5); $('zoom-out').onclick=()=>zoom(1/1.5); $('fit').onclick=()=>{if(ready)fit();};
$('toggle-ids').onclick=()=>{showIds=!showIds;$('toggle-ids').textContent=showIds?'Скрыть ID':'Показать ID';$('toggle-ids').setAttribute('aria-pressed',showIds);schedule();};
$('search-form').onsubmit=e=>{e.preventDefault();if(ready)select(Number($('province-id').value),true);};
$('clear-selection').onclick=()=>{selected=0;$('selection').hidden=true;schedule();};
$('collapse').onclick=()=>{const collapsed=!$('controls').hidden;$('controls').hidden=collapsed;$('collapse').textContent=collapsed?'+':'−';$('collapse').title=collapsed?'Развернуть панель':'Свернуть панель';$('collapse').setAttribute('aria-expanded',!collapsed);};
window.addEventListener('resize',resize);
canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();ready=false;status('Графический контекст потерян. Перезагрузите страницу.');});
async function init() {
  if(!gl)throw new Error('Для просмотра карты требуется браузер с WebGL 2.');
  const [metaResponse,regionResponse]=await Promise.all([fetch('map-data/provinces.json'),fetch('map-data/view-region.json')]);
  if(!regionResponse.ok)throw new Error('Не найдены настройки игровой области');
  region=(await regionResponse.json()).bounds;
  if(!Array.isArray(region)||region.length!==4||!region.every(Number.isFinite)||region[0]<0||region[1]<0||region[2]>width||region[3]>height||region[0]>=region[2]||region[1]>=region[3])throw new Error('Некорректные границы игровой области');
  if(!metaResponse.ok)throw new Error('Не найдены файлы в map-data. Запустите сервер из папки fauxlore.');
  provinces=new Map(Object.entries(await metaResponse.json()).map(([hex,p])=>[p.id,{...p,rgb:parseInt(hex.slice(1),16)}]));
  provinces=new Map([...provinces].filter(([,p])=>p.bbox[2]>=region[0]&&p.bbox[3]>=region[1]&&p.bbox[0]<region[2]&&p.bbox[1]<region[3]));
  regionSlots=(Math.ceil(region[2]/tileSize)-Math.floor(region[0]/tileSize))*(Math.ceil(region[3]/tileSize)-Math.floor(region[1]/tileSize));
  cacheSlots=Math.min(25,regionSlots);
  width=10000;height=10000;tileSize=2048;columns=5;rows=5;
  if(gl.getParameter(gl.MAX_TEXTURE_SIZE)<tileSize||gl.getParameter(gl.MAX_ARRAY_TEXTURE_LAYERS)<cacheSlots)throw new Error('Браузер не поддерживает нужный размер тайлов WebGL.');
  setupGL();
  ready=true;resize();fit();
  if(innerWidth<600 && !$('controls').hidden)$('collapse').click();
  const land=[...provinces.values()].filter(p=>p.kind==='land').length;
  const sea=[...provinces.values()].filter(p=>p.kind==='sea').length;
  const lake=[...provinces.values()].filter(p=>p.kind==='lake').length;
  $('summary').textContent=`${provinces.size.toLocaleString('ru-RU')} провинций · ${land.toLocaleString('ru-RU')} суша · ${sea.toLocaleString('ru-RU')} море · ${lake.toLocaleString('ru-RU')} озёра`;
  status('Карта готова. Тайлы загружаются по мере приближения.',4000);
}
init().catch(error=>{console.error(error);status(error.message);$('summary').textContent='Не удалось загрузить карту';});
