// Tiled ID texture: no source artwork, CPU pixel copy, or network dependency.
const $ = id => document.getElementById(id);
const canvas = $('map'), labels = $('labels'), ctx = labels.getContext('2d');
const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, preserveDrawingBuffer: false });
const view = { x: 0, y: 0, scale: 1, min: 0.01, max: 12 };
let width = 10000, height = 10000, tileSize = 2048, columns = 5;
let ready = false, showIds = false, selected = 0, provinces = new Map(), frame = 0;
let program, texture, pickFramebuffer, loc, statusTimer;
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
  uniform sampler2D uTypes;
  uniform vec2 uViewport,uOffset,uMapSize,uPickPoint;
  uniform float uScale,uDpr;
  uniform int uTileSize,uColumns,uSelected;
  uniform bool uPick;
  out vec4 color;
  ivec3 bytesAt(ivec2 p){
    if(any(lessThan(p,ivec2(0)))||any(greaterThanEqual(p,ivec2(uMapSize))))return ivec3(0);
    ivec2 tile=p/uTileSize;
    return ivec3(round(texelFetch(uIds,ivec3(p%uTileSize,tile.y*uColumns+tile.x),0).rgb*255.));
  }
  int idAt(ivec2 p){ivec3 b=bytesAt(p);return (b.r<<16)|(b.g<<8)|b.b;}
  void main(){
    vec2 screen=vec2(gl_FragCoord.x,uViewport.y-gl_FragCoord.y)/uDpr;
    ivec2 p=ivec2(floor(uPick?uPickPoint:(screen-uOffset)/uScale));
    ivec3 bytes=bytesAt(p); int id=(bytes.r<<16)|(bytes.g<<8)|bytes.b;
    if(uPick){color=vec4(vec3(bytes)/255.,1.);return;}
    if(id==0){color=vec4(.071,.126,.157,1.);return;}
    int kind=int(round(texelFetch(uTypes,ivec2(id%256,id/256),0).r*255.));
    vec3 base=kind==1?vec3(.843,.773,.627):vec3(.255,.425,.49);
    float variation=float((id*7919)%29)/29.-.5;
    base+=variation*(kind==1?.07:.045);
    if(id==uSelected)base=vec3(.941,.776,.396);
    int stepSize=max(1,int(ceil(.75/uScale)));
    bool edge=idAt(p+ivec2(stepSize,0))!=id||idAt(p+ivec2(0,stepSize))!=id;
    if(edge)base=mix(base,vec3(.09,.17,.19),.6);
    color=vec4(base,1.);
  }`);
  program = gl.createProgram(); gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  gl.deleteShader(vertex); gl.deleteShader(fragment); gl.useProgram(program);
  loc = Object.fromEntries(['Ids','Types','Viewport','Offset','MapSize','PickPoint','Scale','Dpr','TileSize','Columns','Selected','Pick'].map(k => [k, gl.getUniformLocation(program, `u${k}`)]));
  gl.uniform1i(loc.Ids, 0); gl.uniform1i(loc.Types, 1);
  gl.uniform2f(loc.MapSize, width, height); gl.uniform1i(loc.TileSize, tileSize); gl.uniform1i(loc.Columns, columns);
  const maxId = Math.max(...provinces.keys());
  const rows = Math.ceil((maxId+1)/256), types = new Uint8Array(256*rows);
  for (const p of provinces.values()) types[p.id] = p.kind === 'land' ? 1 : 2;
  gl.activeTexture(gl.TEXTURE1);
  const typeTexture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, typeTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, 256, rows, 0, gl.RED, gl.UNSIGNED_BYTE, types);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
  texture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D_ARRAY, texture);
  gl.texStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.RGB8, tileSize, tileSize, columns*Math.ceil(height/tileSize));
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  const pickTexture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, pickTexture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  pickFramebuffer = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, pickFramebuffer);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, pickTexture, 0);
  if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) throw new Error('Не удалось подготовить выбор провинций');
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.disable(gl.DITHER); // Exact byte values for picking, including low province IDs.
}
function uniforms() {
  gl.useProgram(program); gl.uniform2f(loc.Viewport, canvas.width, canvas.height);
  gl.uniform2f(loc.Offset, view.x, view.y); gl.uniform1f(loc.Scale, view.scale);
  gl.uniform1f(loc.Dpr, canvas.width/innerWidth); gl.uniform1i(loc.Selected, selected);
}
function draw() {
  frame = 0; if (!ready) return;
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
  view.min = Math.min(innerWidth/width,innerHeight/height)*.85;
  if (ready) { view.x += (innerWidth-oldW)/2; view.y += (innerHeight-oldH)/2; clampView(); }
  schedule();
}
function clampView() {
  view.scale = Math.max(view.min, Math.min(view.max,view.scale));
  const clampAxis = (v,span,screen) => span < screen ? (screen-span)/2 : Math.max(60-span,Math.min(screen-60,v));
  view.x = clampAxis(view.x,width*view.scale,innerWidth); view.y = clampAxis(view.y,height*view.scale,innerHeight);
}
function fit() {
  view.scale = view.min; view.x = (innerWidth-width*view.scale)/2; view.y = (innerHeight-height*view.scale)/2; schedule();
}
function zoom(factor,x=innerWidth/2,y=innerHeight/2) {
  if (!ready) return;
  const next = Math.max(view.min,Math.min(view.max,view.scale*factor));
  const ratio = next/view.scale; view.x = x-(x-view.x)*ratio; view.y = y-(y-view.y)*ratio; view.scale = next;
  clampView(); schedule();
}
function select(id, focus=false) {
  const p = provinces.get(id); if (!p) { status(`Провинция с ID ${id} не найдена`,4000); return; }
  selected = id; $('selection').hidden = false; $('selection-title').textContent = `№ ${id} · ${p.kind === 'land' ? 'Суша' : 'Море'}`;
  $('selection-details').textContent = `Площадь: ${p.area.toLocaleString('ru-RU')} пикс.²`;
  $('province-id').value = id;
  if (focus) {
    const [x0,y0,x1,y1] = p.bbox;
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
  const [metaResponse,imageResponse]=await Promise.all([fetch('map-data/provinces.json'),fetch('map-data/province-ids.png')]);
  if(!metaResponse.ok||!imageResponse.ok)throw new Error('Не найдены файлы в map-data. Запустите сервер из папки fauxlore.');
  provinces=new Map(Object.values(await metaResponse.json()).map(p=>[p.id,p]));
  const blob=await imageResponse.blob();
  const bitmap=await createImageBitmap(blob,{premultiplyAlpha:'none',colorSpaceConversion:'none'});
  width=bitmap.width;height=bitmap.height;tileSize=Math.min(2048,gl.getParameter(gl.MAX_TEXTURE_SIZE));columns=Math.ceil(width/tileSize);
  if(columns*Math.ceil(height/tileSize)>gl.getParameter(gl.MAX_ARRAY_TEXTURE_LAYERS))throw new Error('Недостаточно доступных слоёв текстуры для этой карты.');
  setupGL();
  const total=columns*Math.ceil(height/tileSize);let loaded=0;
  for(let y=0;y<height;y+=tileSize)for(let x=0;x<width;x+=tileSize){
    const w=Math.min(tileSize,width-x),h=Math.min(tileSize,height-y);
    const tile=await createImageBitmap(bitmap,x,y,w,h,{premultiplyAlpha:'none',colorSpaceConversion:'none'});
    gl.texSubImage3D(gl.TEXTURE_2D_ARRAY,0,0,0,Math.floor(y/tileSize)*columns+Math.floor(x/tileSize),w,h,1,gl.RGB,gl.UNSIGNED_BYTE,tile);tile.close();
    const error=gl.getError();if(error!==gl.NO_ERROR)throw new Error(`Ошибка загрузки текстуры (${error}). Возможно, недостаточно видеопамяти.`);
    status(`Подготовка карты: ${++loaded}/${total}`); await new Promise(requestAnimationFrame);
  }
  bitmap.close(); ready=true;resize();fit();
  if(innerWidth<600 && !$('controls').hidden)$('collapse').click();
  const land=[...provinces.values()].filter(p=>p.kind==='land').length;
  $('summary').textContent=`${provinces.size.toLocaleString('ru-RU')} провинций · ${land.toLocaleString('ru-RU')} суша · ${(provinces.size-land).toLocaleString('ru-RU')} море`;
  status('Карта готова. Нажмите на провинцию, чтобы узнать её ID.',4000);
}
init().catch(error=>{console.error(error);status(error.message);$('summary').textContent='Не удалось загрузить карту';});
