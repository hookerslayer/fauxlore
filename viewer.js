import {initUI,hydrateUI,api,loadInitialMap,settings,LAYERS,isAdmin,isAdminEditing,isAdminPainting,canRenameProvince,canRenameMarker} from './ui.js?v=manual-military-20261031';
import {militaryMapApi,militaryOrderApi,provinceProjectionApi} from './supabase-api.js?v=manual-military-20261031';
import {distance,polygonArea,simplePolygon,niceLength} from './map-tools.js';
// PostgreSQL metadata + tiled WebGL geometry, no full CPU pixel copy.
const $ = id => document.getElementById(id);
const html = value => String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const canvas = $('map'), labels = $('labels'), ctx = labels.getContext('2d');
const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, preserveDrawingBuffer: false });
const view = { x: 0, y: 0, scale: 1, min: 0.01, max: 12 };
let viewportWidth=window.innerWidth,viewportHeight=window.innerHeight;
const provinceProjectionCache=new Map(),provinceProjectionPending=new Map();
let width = 10000, height = 10000, tileSize = 2048, columns = 5, rows = 5;
let tileRevision = '0';
let dataRevision = '0', liveRevision = '0', syncTimer = 0, syncInProgress = false;
let ready = false, showIds = false, selected = 0, provinces = new Map(), categoryList=[],provinceAdjacency={}, frame = 0, adminPaint=null,tradeRouteMode=false,tradeRouteIds=[],colonizationRouteMode=false,colonizationRouteIds=[],militaryMoveDraft=null,militaryChipPlacement=null,portPlacement=null,fortPlacement=null;
let program, texture, tileSlotsTexture, pickFramebuffer, loc, statusTimer;
let cacheSlots = 25, tileCache = new Map(), tileLoading = new Map(), tileUse = 0;
let region = [0, 0, 10000, 10000]; // min x/y inclusive, max x/y exclusive
let regionSlots = 25;
const MILITARY_TOKEN_RADIUS=2.695;
const MILITARY_TOKEN_HIT_PADDING=.98;
const militaryTokenIcons=Object.fromEntries(['army','fleet'].map(type=>{const image=new Image();image.src=`assets/icons/military-${type}.svg?v=military-token-colors-20261027`;image.onload=schedule;return[type,image];}));
const tintedMilitaryIconCache=new Map();
function tintedMilitaryIcon(type,color){
  const source=militaryTokenIcons[type];if(!source?.complete||!source.naturalWidth)return null;
  const tint=/^#[0-9a-f]{6}$/i.test(color)?color:'#6e7669',key=`${type}:${tint}`;if(tintedMilitaryIconCache.has(key))return tintedMilitaryIconCache.get(key);
  const icon=document.createElement('canvas');icon.width=32;icon.height=32;const iconContext=icon.getContext('2d');iconContext.drawImage(source,0,0,32,32);iconContext.globalCompositeOperation='source-in';iconContext.fillStyle=tint;iconContext.fillRect(0,0,32,32);tintedMilitaryIconCache.set(key,icon);return icon;
}
let colorsTexture,occupationColorsTexture,terrainTexture,fogVisibilityTexture,activeSettings=settings,toolMode='',toolPoints=[],areaClosed=false,lastPoint=null,mapMilitary=[],militaryHitTargets=[],constructionHitTargets=[],militaryRefreshTimer=null,militaryRequestToken=0;
const thematicComponents=new Map();
let mapMarkers=[],mapColonies=[],applicationPlacement=null,applicationSelectedIds=new Set();
let selectedMarkerPopup=null;
let mapTradeRoutes=[];
function drawTradeRoutes(){
  if(!activeSettings.information.routes||!mapTradeRoutes.length)return;
  const provincePoint=id=>{
    const province=provinces.get(Number(id));
    if(!province)return null;
    const center=Array.isArray(province.center)?province.center:null;
    return center&&Number.isFinite(Number(center[0]))&&Number.isFinite(Number(center[1]))?[Number(center[0]),Number(center[1])]:null;
  };
  const cityPoint=(provinceId,stateId)=>{
    const marker=mapMarkers.find(item=>Number(item.province_id)===Number(provinceId)&&['city','capital'].includes(item.type)&&(!stateId||Number(item.state_id)===Number(stateId)));
    if(marker&&Number.isFinite(Number(marker.x))&&Number.isFinite(Number(marker.y)))return[Number(marker.x),Number(marker.y)];
    return provincePoint(provinceId);
  };
  ctx.save();ctx.lineCap='round';ctx.lineJoin='round';
  for(const route of mapTradeRoutes){
    const ids=route.route_province_ids||[];
    if(ids.length<2)continue;
    const points=[cityPoint(ids[0],route.from_state_id),...ids.slice(1,-1).map(provincePoint),cityPoint(ids[ids.length-1],route.to_state_id)];
    if(points.some(point=>!point))continue;
    ctx.beginPath();points.forEach(([x,y],i)=>{x=x*view.scale+view.x;y=y*view.scale+view.y;i?ctx.lineTo(x,y):ctx.moveTo(x,y);});
    ctx.setLineDash([7,5]);ctx.strokeStyle='#10100d';ctx.lineWidth=4;ctx.stroke();
    ctx.strokeStyle='#f0cf66';ctx.lineWidth=2;ctx.stroke();
  }
  ctx.restore();
}
const markerIcons=Object.fromEntries(['capital','city','fortress','port'].map(type=>{const image=new Image();image.src=`assets/markers/${type}.svg`;image.onload=schedule;return[type,image];}));
const MARKER_HEIGHT={capital:12,city:10,fortress:8,port:6};
const status = (text, timeout = 0) => {
  clearTimeout(statusTimer); $('status').textContent = text;
  if (timeout) statusTimer = setTimeout(() => { $('status').textContent = ''; }, timeout);
};
function schedule() { if (!frame) frame = requestAnimationFrame(draw); }

function drawMilitaryRoute(route){
  if(!Array.isArray(route)||route.length<2)return;
  const points=route.map(point=>({x:Number(point.x)*view.scale+view.x,y:Number(point.y)*view.scale+view.y}));
  if(points.some(point=>!Number.isFinite(point.x)||!Number.isFinite(point.y)))return;
  ctx.beginPath();ctx.moveTo(points[0].x,points[0].y);
  for(const point of points.slice(1))ctx.lineTo(point.x,point.y);
  ctx.setLineDash([7,5]);ctx.strokeStyle='#101311';ctx.lineWidth=5;ctx.stroke();
  ctx.strokeStyle='#ffe06a';ctx.lineWidth=2.5;ctx.stroke();ctx.setLineDash([]);
  for(const point of [points[0],points.at(-1)]){
    ctx.beginPath();ctx.arc(point.x,point.y,4,0,Math.PI*2);
    ctx.fillStyle='#ffe06a';ctx.fill();ctx.lineWidth=1.75;ctx.strokeStyle='#101311';ctx.stroke();
  }
}
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
  uniform sampler2D uOccupationColors;
  uniform sampler2D uTerrain;
  uniform sampler2D uFogVisibility;
  uniform vec2 uViewport,uOffset,uMapSize,uPickPoint;
  uniform vec4 uRegion;
  uniform float uScale;
  uniform vec2 uDpr;
  uniform int uTileSize,uColumns,uSelected,uRouteIds[50],uRouteCount;
  uniform bool uPick,uShowOccupation,uFogEnabled;
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
    vec2 screen=vec2(gl_FragCoord.x/uDpr.x,(uViewport.y-gl_FragCoord.y)/uDpr.y);
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
    bool routeSelected=false;
    for(int i=0;i<50;i++)if(i<uRouteCount&&id==uRouteIds[i])routeSelected=true;
    if(routeSelected)base=mix(base,vec3(1.,.86,.38),.64);

    vec4 occupation=texelFetch(uOccupationColors,ivec2(id%256,id/256),0);
    if(occupation.a>.5&&uShowOccupation&&mod(float(p.x+p.y),12.)<2.)base=mix(base,occupation.rgb,.92);

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

    // Terrain glyphs are map-space pixels, composited after relief, thematic
    // fills, selection, occupation hatching, rivers and borders. Labels/markers
    // are rendered by the later overlay canvas and remain above this pass.
    int terrain=int(round(texelFetch(uTerrain,ivec2(id%256,id/256),0).r*255.));
    if(kind==1&&terrain==3&&mod(float(p.x-p.y+120000),12.)<2.)base=mix(base,vec3(.12,.07,.07),.7);
    if(kind==1&&terrain!=0){
      bool mark=false;
      if(terrain==1){
        ivec2 cell=p/4;
        int h=(cell.x*73+cell.y*151+(cell.x*cell.y)%997*19)%997;
        ivec2 q=p%4;
        int dotX=h%2,dotY=(h/7)%2;
        mark=q.x>=dotX&&q.x<dotX+2&&q.y>=dotY&&q.y<dotY+2;
      }else if(terrain==2){
        int row=p.y/6;
        int x=(p.x+(row%2)*6)%12,y=p.y%6;
        int dashLength=3+(row*7)%3;
        mark=y==2&&x<dashLength;
      }
      if(mark){
        vec3 multiplyColor=terrain==1?vec3(.50,.38,.32):vec3(.42,.30,.24);
        base*=mix(vec3(1.),multiplyColor,.4);
      }
    }
    if(uFogEnabled&&texelFetch(uFogVisibility,ivec2(id%256,id/256),0).r<.5)base*=.8;
    color=vec4(base,1.);
  }`);
  program = gl.createProgram(); gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  gl.deleteShader(vertex); gl.deleteShader(fragment); gl.useProgram(program);
  loc = Object.fromEntries(['Ids','Types','Colors','OccupationColors','Terrain','FogVisibility','FogEnabled','TileSlots','Region','Viewport','Offset','MapSize','PickPoint','Scale','Dpr','TileSize','Columns','Selected','Pick','ShowOccupation','RouteCount'].map(k => [k, gl.getUniformLocation(program, `u${k}`)]));
  loc.RouteIds=gl.getUniformLocation(program,'uRouteIds[0]');
  gl.uniform4f(loc.Region,...region);
  gl.uniform1i(loc.Ids, 0); gl.uniform1i(loc.Types, 1); gl.uniform1i(loc.TileSlots, 2);
  gl.uniform1i(loc.Colors,4);
  gl.uniform1i(loc.OccupationColors,5);
  gl.uniform1i(loc.Terrain,6);
  gl.uniform1i(loc.FogVisibility,7);
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
  colorsTexture=gl.createTexture(); occupationColorsTexture=gl.createTexture(); terrainTexture=gl.createTexture(); fogVisibilityTexture=gl.createTexture(); updateLayerColors(); updateTerrainTypes(); updateFogVisibility();
}
function updateFogVisibility(){
  if(!fogVisibilityTexture)return;
  const maxId=Math.max(...provinces.keys()),height=Math.ceil((maxId+1)/256),visibility=new Uint8Array(256*height);
  if(!mapMilitary?.fog_of_war)visibility.fill(255);
  else for(const id of mapMilitary.visible_provinces||[])if(Number.isInteger(Number(id))&&Number(id)>=0&&Number(id)<=maxId)visibility[Number(id)]=255;
  gl.activeTexture(gl.TEXTURE7);gl.bindTexture(gl.TEXTURE_2D,fogVisibilityTexture);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.R8,256,height,0,gl.RED,gl.UNSIGNED_BYTE,visibility);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
}
function updateTerrainTypes(){
  if(!terrainTexture)return;
  const maxId=Math.max(...provinces.keys()),height=Math.ceil((maxId+1)/256),terrain=new Uint8Array(256*height);
  for(const p of provinces.values())if(p.kind==='land')terrain[p.id]=p.application_pending?3:({forest:1,marsh:2}[p.terrain_type]||0);
  gl.activeTexture(gl.TEXTURE6);gl.bindTexture(gl.TEXTURE_2D,terrainTexture);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.R8,256,height,0,gl.RED,gl.UNSIGNED_BYTE,terrain);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
}
function updateLayerColors(){
  if(!colorsTexture)return;
  const maxId=Math.max(...provinces.keys()),height=Math.ceil((maxId+1)/256),colors=new Uint8Array(256*height*4);
  const occupations=new Uint8Array(256*height*4);
  const layer=activeSettings.layer,categoryLayer=layer==='military'?'states':layer;
  gl.useProgram(program);gl.uniform1i(loc.ShowOccupation,layer==='states'||layer==='military'?1:0);
  const numeric=p=>layer==='population'?(p.kind==='land'&&p.population!=null?Number(p.population):null):(p.development==null?null:Number(p.development));
  const numbers=['population','development'].includes(layer)?[...provinces.values()].map(numeric).filter(v=>v!==null):[];
  const min=numbers.length?Math.min(...numbers):0,max=numbers.length?Math.max(...numbers):0;
  for(const p of provinces.values()){
    let rgb;
    const category=p.layers?.[categoryLayer];
    if(applicationSelectedIds.has(Number(p.id)))rgb=[238,190,82];
    else if(category&&/^#[0-9a-f]{6}$/i.test(category.color))rgb=category.color.slice(1).match(/../g).map(x=>parseInt(x,16));
    else if(numbers.length&&numeric(p)!==null){const t=max===min?.5:(numeric(p)-min)/(max-min);rgb=[Math.round(55+177*t),Math.round(65+133*t),Math.round(62+41*t)];}
    if(rgb)colors.set([...rgb,255],p.id*4);
    const colony=mapColonies.find(item=>Number(item.province_id)===Number(p.id));
    if(colony?.color){const colonyRgb=colony.color.slice(1).match(/../g).map(x=>parseInt(x,16));occupations.set([...colonyRgb,128],p.id*4);}
    else if(p.occupation_color){const occupationRgb=p.occupation_color.slice(1).match(/../g).map(x=>parseInt(x,16));occupations.set([...occupationRgb,255],p.id*4);}
  }
  gl.activeTexture(gl.TEXTURE4);gl.bindTexture(gl.TEXTURE_2D,colorsTexture);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,256,height,0,gl.RGBA,gl.UNSIGNED_BYTE,colors);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  gl.activeTexture(gl.TEXTURE5);gl.bindTexture(gl.TEXTURE_2D,occupationColorsTexture);
  gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA8,256,height,0,gl.RGBA,gl.UNSIGNED_BYTE,occupations);
  gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
  gl.activeTexture(gl.TEXTURE0);
}
function uniforms() {
  gl.useProgram(program); gl.uniform2f(loc.Viewport, canvas.width, canvas.height);
  gl.uniform2f(loc.Offset, view.x, view.y); gl.uniform1f(loc.Scale, view.scale);
  gl.uniform2f(loc.Dpr, canvas.width/viewportWidth, canvas.height/viewportHeight); gl.uniform1i(loc.Selected, selected);
  gl.uniform1i(loc.FogEnabled,activeSettings.layer==='military'&&!!mapMilitary?.fog_of_war);
  const routeHighlights=[...tradeRouteIds,...colonizationRouteIds].slice(0,50);
  gl.uniform1iv(loc.RouteIds,Int32Array.from(Array.from({length:50},(_,i)=>Number(routeHighlights[i])||0)));
  gl.uniform1i(loc.RouteCount,routeHighlights.length);
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
  const worldRight=(viewportWidth-view.x)/view.scale, worldBottom=(viewportHeight-view.y)/view.scale;
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
async function loadTile(tx,ty,slot){const key=`${tx},${ty}`;tileLoading.set(key,slot);try{const response=await fetch(`map-data/tiles/${key.replace(',', '_')}.png?v=${tileRevision}`);if(!response.ok)throw new Error(`Не найден тайл ${key}`);const bitmap=await createImageBitmap(await response.blob(),{premultiplyAlpha:'none',colorSpaceConversion:'none'});gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D_ARRAY,texture);gl.texSubImage3D(gl.TEXTURE_2D_ARRAY,0,0,0,slot,bitmap.width,bitmap.height,1,gl.RGBA,gl.UNSIGNED_BYTE,bitmap);bitmap.close();const current=tileCache.get(key);if(current&&current.slot===slot){gl.activeTexture(gl.TEXTURE2);gl.bindTexture(gl.TEXTURE_2D,tileSlotsTexture);gl.texSubImage2D(gl.TEXTURE_2D,0,tx,ty,1,1,gl.RED,gl.UNSIGNED_BYTE,new Uint8Array([slot+1]));gl.activeTexture(gl.TEXTURE0);}}catch(error){console.warn(error)}finally{if(tileLoading.get(key)===slot)tileLoading.delete(key);for(const components of thematicComponents.values())for(const component of components)component.labelWaiting=false;schedule();}}
function ensureVisibleTiles(){const visible=new Set(tileRange().map(([x,y])=>`${x},${y}`));for(const key of visible){const [tx,ty]=key.split(',').map(Number);const slot=tileSlotFor(key,visible);if(slot<0||tileLoading.has(key))continue;if(!tileCache.get(key)?.loaded){tileCache.get(key).loaded=true;loadTile(tx,ty,slot);}}}
function updateTileCapacity(){const next=Math.min(regionSlots,view.scale>view.min*1.8?12:25);if(next!==cacheSlots)resetTileCache(next);}
function draw() {
  frame = 0; if (!ready) return;
  updateTileCapacity(); ensureVisibleTiles();
  gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0,0,canvas.width,canvas.height);
  uniforms(); gl.uniform1i(loc.Pick, 0); gl.drawArrays(gl.TRIANGLES,0,3);
  drawLabels(); drawMeasurements(); updateScale();
  if(selectedMarkerPopup){
    const x=selectedMarkerPopup.x*view.scale+view.x,y=selectedMarkerPopup.y*view.scale+view.y;
    window.dispatchEvent(new CustomEvent('map:marker-position',{detail:{id:selectedMarkerPopup.id,x,y,visible:x>=0&&x<=viewportWidth&&y>=0&&y<=viewportHeight}}));
  }
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
    const bounds=members.reduce((b,p)=>{const r=Math.sqrt(Math.max(1,p.area)/Math.PI);return[Math.min(b[0],p.center[0]-r),Math.min(b[1],p.center[1]-r),Math.max(b[2],p.center[0]+r),Math.max(b[3],p.center[1]+r)];},[Infinity,Infinity,-Infinity,-Infinity]);
    components.push({name:category.name,layer,categoryId:category.id,members,area,center,bounds});
  }
  components.sort((a,b)=>b.area-a.area);thematicComponents.set(layer,components);return components;
}
function pointOnPath(path,distance){
  let remaining=distance;
  for(let i=1;i<path.length;i++){
    const a=path[i-1],b=path[i],length=Math.hypot(b[0]-a[0],b[1]-a[1]);
    if(remaining<=length||i===path.length-1){const t=length?Math.max(0,Math.min(1,remaining/length)):0;return{x:a[0]+(b[0]-a[0])*t,y:a[1]+(b[1]-a[1])*t,angle:Math.atan2(b[1]-a[1],b[0]-a[0])};}
    remaining-=length;
  }
  return{x:path[0][0],y:path[0][1],angle:0};
}
function thematicLabelPlacement(component){
  const members=component.members;if(!members.length)return null;
  let xx=0,xy=0,yy=0,total=0;
  for(const p of members){const weight=Math.max(1,p.area),dx=p.center[0]-component.center[0],dy=p.center[1]-component.center[1];xx+=weight*dx*dx;xy+=weight*dx*dy;yy+=weight*dy*dy;total+=weight;}
  const angle=.5*Math.atan2(2*xy,xx-yy),axis=[Math.cos(angle),Math.sin(angle)];
  if(axis[0]<0){axis[0]*=-1;axis[1]*=-1;}
  const normal=[-axis[1],axis[0]],points=members.map(p=>{
    const dx=p.center[0]-component.center[0],dy=p.center[1]-component.center[1],radius=Math.sqrt(Math.max(1,p.area)/Math.PI);
    return{t:dx*axis[0]+dy*axis[1],n:dx*normal[0]+dy*normal[1],radius,weight:Math.max(1,p.area)};
  });
  const low=Math.min(...points.map(p=>p.t-p.radius)),high=Math.max(...points.map(p=>p.t+p.radius));
  const nLow=Math.min(...points.map(p=>p.n-p.radius)),nHigh=Math.max(...points.map(p=>p.n+p.radius));
  const major=high-low,minor=nHigh-nLow;if(major<1||minor<1)return null;
  const bins=Math.max(3,Math.min(9,Math.round(Math.sqrt(members.length)))),sums=Array.from({length:bins},()=>({n:0,w:0}));
  for(const p of points){const index=Math.max(0,Math.min(bins-1,Math.floor((p.t-low)/major*bins)));sums[index].n+=p.n*p.weight;sums[index].w+=p.weight;}
  const values=sums.map((bin,i)=>bin.w?bin.n/bin.w:null);
  for(let i=0;i<bins;i++)if(values[i]===null){let before=i-1,after=i+1;while(before>=0&&values[before]===null)before--;while(after<bins&&values[after]===null)after++;values[i]=before>=0&&after<bins?values[before]+(values[after]-values[before])*(i-before)/(after-before):before>=0?values[before]:after<bins?values[after]:0;}
  const smoothed=values.map((value,i)=>(values[Math.max(0,i-1)]+2*value+values[Math.min(bins-1,i+1)])/4);
  const path=smoothed.map((n,i)=>{const t=low+major*i/(bins-1);return[component.center[0]+axis[0]*t+normal[0]*n,component.center[1]+axis[1]*t+normal[1]*n];});
  const pathLength=path.slice(1).reduce((sum,p,i)=>sum+Math.hypot(p[0]-path[i][0],p[1]-path[i][1]),0);
  ctx.save();ctx.font='600 100px system-ui';const textRatio=ctx.measureText(component.name).width/100;ctx.restore();
  let fontSize=Math.min(minor*.29,major*.34/Math.max(textRatio,.1));
  if(fontSize*view.scale<8)return{deferred:true};
  for(let attempt=0;attempt<4;attempt++,fontSize*=.82){
    const textWidth=textRatio*fontSize;if(textWidth>pathLength*.9)continue;
    const start=(pathLength-textWidth)/2,samples=5;let fits=true,waiting=false;
    for(let i=0;i<samples&&fits;i++){
      const point=pointOnPath(path,start+textWidth*i/(samples-1)),nx=-Math.sin(point.angle),ny=Math.cos(point.angle);
      for(const offset of [-fontSize*.5,0,fontSize*.5]){
        const wx=point.x+nx*offset,wy=point.y+ny*offset,tx=Math.floor(wx/tileSize),ty=Math.floor(wy/tileSize);
        if(wx<region[0]||wy<region[1]||wx>=region[2]||wy>=region[3]){fits=false;break;}
        const sx=wx*view.scale+view.x,sy=wy*view.scale+view.y;if(sx<0||sx>viewportWidth||sy<0||sy>viewportHeight)continue;
        if(!tileCache.has(`${tx},${ty}`)){waiting=true;fits=false;break;}
        const id=pickProvinceId(wx*view.scale+view.x,wy*view.scale+view.y),province=provinces.get(id);
        if(!province||String(province.layers?.[component.layer]?.id)!==String(component.categoryId)){fits=false;break;}
      }
    }
    if(waiting)return undefined;
    if(fits)return{path,pathLength,fontSize,hidden:false};
  }
  return null;
}
function drawThematicLabel(component,placement,paint=true){
  if(placement.hidden)return null;
  const fontSize=placement.fontSize*view.scale;if(fontSize<8)return null;
  ctx.save();ctx.font=`700 ${fontSize}px system-ui`;ctx.textAlign='center';ctx.textBaseline='middle';ctx.lineJoin='round';ctx.lineWidth=Math.max(.75,fontSize*.06);ctx.strokeStyle='#13232ddd';ctx.fillStyle='#e7c667';
  const chars=Array.from(component.name),widths=chars.map(char=>ctx.measureText(char).width),textWidth=widths.reduce((a,b)=>a+b,0),start=(placement.pathLength-textWidth/view.scale)/2;let cursor=0,minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;
  for(let i=0;i<chars.length;i++){
    const point=pointOnPath(placement.path,start+(cursor+widths[i]/2)/view.scale);cursor+=widths[i];
    const x=point.x*view.scale+view.x,y=point.y*view.scale+view.y,halfWidth=(widths[i]+fontSize)*.5;minX=Math.min(minX,x-halfWidth);maxX=Math.max(maxX,x+halfWidth);minY=Math.min(minY,y-fontSize);maxY=Math.max(maxY,y+fontSize);
    if(paint){ctx.save();ctx.translate(x,y);ctx.rotate(point.angle);ctx.strokeText(chars[i],0,0);ctx.fillText(chars[i],0,0);ctx.restore();}
  }
  const outline=Math.max(.75,fontSize*.06);ctx.restore();return{left:minX-outline,right:maxX+outline,top:minY-outline,bottom:maxY+outline};
}
function drawLabels() {
  const dprX = labels.width/viewportWidth,dprY=labels.height/viewportHeight;
  // Markers are part of the map composition: their anchors, icon sizes, and label offsets all follow map zoom.
  ctx.setTransform(dprX,0,0,dprY,0,0); ctx.clearRect(0,0,viewportWidth,viewportHeight);
  drawTradeRoutes();
  const showMarkers=Object.keys(markerIcons).some(type=>activeSettings.markers?.[type])&&mapMarkers.length>0||activeSettings.markers?.capital||activeSettings.markers?.city;
  if (!showIds&&!Object.values(activeSettings.information).some(Boolean)&&!showMarkers&&activeSettings.layer!=='military') return;
  const markersByProvince=new Map();
  for(const marker of mapMarkers)if(activeSettings.markers?.[marker.type]){const list=markersByProvince.get(marker.province_id)||[];list.push(marker);markersByProvince.set(marker.province_id,list);}
  ctx.font = '600 11px system-ui'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.lineWidth = 3; ctx.strokeStyle = '#13232ddd'; ctx.fillStyle = '#fff9e8';
  const occupied = new Set(),labelRects=[];
  const ordered = [...provinces.values()].sort((a,b) => (b.id===selected)-(a.id===selected) || b.area-a.area);
  for (const p of ordered) {
    if(p.center[0]<region[0]||p.center[1]<region[1]||p.center[0]>=region[2]||p.center[1]>=region[3])continue;
    const x = p.center[0]*view.scale+view.x, y = p.center[1]*view.scale+view.y;
    const key = `${Math.floor(x/42)},${Math.floor(y/18)}`;
    const visibleMarkers=markersByProvince.get(p.id)||[];
    if(activeSettings.markers?.capital&&p.has_capital_marker&&!visibleMarkers.some(m=>m.type==='capital'))visibleMarkers.push({type:'capital',name:p.name});
    if(activeSettings.markers?.city&&p.has_city_marker&&!visibleMarkers.some(m=>m.type==='city'))visibleMarkers.push({type:'city',name:p.name});
    const hasVisibleMarker=visibleMarkers.length>0;
    const markerRows=activeSettings.markers?.names?visibleMarkers.filter(marker=>marker.name):[];
    if(hasVisibleMarker)visibleMarkers.forEach(marker=>{
        const mx=(Number.isFinite(marker.x)?marker.x:p.center[0])*view.scale+view.x;
        const my=(Number.isFinite(marker.y)?marker.y:p.center[1])*view.scale+view.y;
        const size=(MARKER_HEIGHT[marker.type]||10)*view.scale,image=markerIcons[marker.type];
        const imageRatio=image?.naturalWidth&&image?.naturalHeight?image.naturalWidth/image.naturalHeight:1;
        const iconWidth=size*imageRatio;
        if(mx<-iconWidth||my<-size||mx>viewportWidth+iconWidth||my>viewportHeight+size)return;
        if(image?.complete&&image.naturalWidth){ctx.drawImage(image,mx-iconWidth/2,my-size/2,iconWidth,size);labelRects.push({left:mx-iconWidth/2-2,right:mx+iconWidth/2+2,top:my-size/2-2,bottom:my+size/2+2});}
        const name=markerRows.includes(marker)?marker.name:null;
        if(name){
          const labelSize=size*(2/3);
          ctx.font=`600 ${labelSize}px system-ui`;ctx.textAlign='left';ctx.textBaseline='middle';
          const left=mx+iconWidth/2+1.5*view.scale;
          ctx.lineWidth=.75*view.scale;ctx.lineJoin='round';ctx.strokeStyle='#000';ctx.fillStyle='#fff';
          ctx.strokeText(name,left,my);ctx.fillText(name,left,my);const width=ctx.measureText(name).width;labelRects.push({left:left-2,right:left+width+2,top:my-labelSize/2-2,bottom:my+labelSize/2+2});
        }
      });
    if (x < -30 || y < -10 || x > viewportWidth+30 || y > viewportHeight+10) continue;
    if (occupied.has(key) && p.id !== selected) continue;
    const text=showIds?String(p.id):(!hasVisibleMarker||!activeSettings.markers?.names)&&activeSettings.information.provinces?p.name:'';
    if(!text)continue;
    occupied.add(key);ctx.textAlign='center';ctx.textBaseline='middle';ctx.font='600 11px system-ui';ctx.lineWidth=3;ctx.strokeStyle='#13232ddd';ctx.fillStyle='#fff9e8';const textWidth=ctx.measureText(text).width;labelRects.push({left:x-textWidth/2-3,right:x+textWidth/2+3,top:y-9,bottom:y+9});ctx.strokeText(text,x,y); ctx.fillText(text,x,y);
  }
  let pendingLabelLayout=false,layoutsThisFrame=0;
  for(const layer of ['states','races','religions','resources','trade']){
    if(!activeSettings.information[layer])continue;
    const components=getThematicComponents(layer);
    for(const component of components){
      const [minX,minY,maxX,maxY]=component.bounds.map((value,index)=>value*view.scale+(index%2===0?view.x:view.y));
      if(maxX<0||minX>viewportWidth||maxY<0||minY>viewportHeight)continue;
      if(!component.labelPlacement&&!component.labelWaiting&&component.labelDeferredScale!==view.scale&&layoutsThisFrame<2){layoutsThisFrame++;const placement=thematicLabelPlacement(component);if(placement===undefined)component.labelWaiting=true;else if(placement?.deferred)component.labelDeferredScale=view.scale;else component.labelPlacement=placement||{hidden:true};}
      if(!component.labelPlacement){if(!component.labelWaiting&&component.labelDeferredScale!==view.scale&&layoutsThisFrame>=2)pendingLabelLayout=true;continue;}
      const rect=drawThematicLabel(component,component.labelPlacement,false);if(!rect)continue;
      if(rect.right<0||rect.left>viewportWidth||rect.bottom<0||rect.top>viewportHeight)continue;
      const key=`${Math.floor((rect.left+rect.right)/84)},${Math.floor((rect.top+rect.bottom)/36)}`;
      if(occupied.has(key)||labelRects.some(other=>rect.left<other.right+4&&rect.right>other.left-4&&rect.top<other.bottom+4&&rect.bottom>other.top-4))continue;
      occupied.add(key);labelRects.push(rect);drawThematicLabel(component,component.labelPlacement,true);
    }
  }
  militaryHitTargets=[];
  if(activeSettings.layer==='military'){
    ctx.save();ctx.lineCap='round';ctx.lineJoin='round';
    for(const item of mapMilitary.formations||[]){const order=item.pending_order;if(!order)continue;const route=order.route.map((id,index)=>index===0?{x:Number(item.x),y:Number(item.y)}:index===order.route.length-1?{x:Number(order.destination_x),y:Number(order.destination_y)}:{x:Number(provinces.get(Number(id))?.center?.[0]),y:Number(provinces.get(Number(id))?.center?.[1])});ctx.globalAlpha=1;drawMilitaryRoute(route);}
    ctx.restore();
  }
  if(militaryMoveDraft?.route?.length>1){ctx.save();ctx.globalAlpha=1;ctx.lineCap='round';ctx.lineJoin='round';drawMilitaryRoute(militaryMoveDraft.route);ctx.restore();}
  if(activeSettings.layer==='military'){
    const tokens=(mapMilitary.formations||[]).map(item=>({...item,token_type:item.domain==='naval'?'fleet':'army'}));
    tokens.sort((a,b)=>Number(a.province_id)-Number(b.province_id)||String(a.token_type).localeCompare(String(b.token_type))||Number(a.id||0)-Number(b.id||0));
    for(const item of tokens){
      const province=provinces.get(Number(item.province_id));if(!province)continue;
      const x=Number(item.x??province.center[0])*view.scale+view.x,y=Number(item.y??province.center[1])*view.scale+view.y;
      const r=MILITARY_TOKEN_RADIUS*view.scale,padding=matchMedia('(pointer:coarse)').matches?Math.max(MILITARY_TOKEN_HIT_PADDING*view.scale,22-r):MILITARY_TOKEN_HIT_PADDING*view.scale;
      if(x<-240||y<-240||x>viewportWidth+240||y>viewportHeight+240)continue;
      const color=/^#[0-9a-f]{6}$/i.test(item.state_color)?item.state_color:'#6e7669';
      ctx.save();ctx.fillStyle='#fff';ctx.strokeStyle=color;ctx.lineWidth=1*view.scale;ctx.beginPath();ctx.arc(x,y,r,0,Math.PI*2);ctx.fill();ctx.stroke();const icon=tintedMilitaryIcon(item.token_type,color),iconSize=r*1.8;if(icon)ctx.drawImage(icon,x-iconSize/2,y-iconSize/2,iconSize,iconSize);ctx.restore();
      militaryHitTargets.push({left:x-r-padding,right:x+r+padding,top:y-r-padding,bottom:y+r+padding,x,y,item});
    }
  }
  constructionHitTargets=[];
  for(const item of mapMilitary.constructions||[]){
    const x=Number(item.x)*view.scale+view.x,y=Number(item.y)*view.scale+view.y;
    if(!Number.isFinite(x)||!Number.isFinite(y)||x<-32||y<-32||x>viewportWidth+32||y>viewportHeight+32)continue;
    const size=Math.max(16,Math.min(26,18*view.scale)),image=markerIcons[item.object_type==='port'?'port':'fortress'];
    if(image?.complete&&image.naturalWidth){const width=size*image.naturalWidth/image.naturalHeight;ctx.save();ctx.globalAlpha=.42;ctx.drawImage(image,x-width/2,y-size/2,width,size);ctx.restore();}
    ctx.save();ctx.fillStyle='#111612ed';ctx.strokeStyle=/^#[0-9a-f]{6}$/i.test(item.state_color)?item.state_color:'#e7c667';ctx.lineWidth=1.5;ctx.beginPath();ctx.arc(x+size*.38,y-size*.34,7,0,Math.PI*2);ctx.fill();ctx.stroke();
    ctx.translate(x+size*.38,y-size*.34);ctx.rotate(-Math.PI/4);ctx.fillStyle='#f0cf67';ctx.fillRect(-1,0,2,7);ctx.fillRect(-4,-3,8,3);ctx.restore();
    constructionHitTargets.push({left:x-size*.7,right:x+size*.7,top:y-size*.7,bottom:y+size*.7,item:{...item,token_type:'construction'}});
  }
  if(pendingLabelLayout)schedule();
}

function pickMilitary(x,y){
  if(activeSettings.layer!=='military')return null;
  const hits=militaryHitTargets.filter(hit=>x>=hit.left&&x<=hit.right&&y>=hit.top&&y<=hit.bottom);
  return hits.sort((a,b)=>Math.hypot(x-a.x,y-a.y)-Math.hypot(x-b.x,y-b.y))[0]||null;
}
function pickConstruction(x,y){
  for(let i=constructionHitTargets.length-1;i>=0;i--){const hit=constructionHitTargets[i];if(x>=hit.left&&x<=hit.right&&y>=hit.top&&y<=hit.bottom)return hit;}
  return null;
}
async function refreshMapMilitary(){
  const token=++militaryRequestToken;
  try{const [data,orderData]=await Promise.all([militaryMapApi(),militaryOrderApi('snapshot').catch(()=>({orders:[]}))]);if(token!==militaryRequestToken)return;mapMilitary=data||{formations:[],garrisons:[]};for(const item of mapMilitary.formations||[])item.pending_order=(orderData.orders||[]).find(order=>Number(order.formation_id)===Number(item.id));updateFogVisibility();window.dispatchEvent(new CustomEvent('map:military-data',{detail:mapMilitary}));if(selected)emitSelectedGarrisonInfo();schedule();}
  catch{if(token===militaryRequestToken){mapMilitary={formations:[],garrisons:[]};updateFogVisibility();window.dispatchEvent(new CustomEvent('map:military-data',{detail:mapMilitary}));if(selected)emitSelectedGarrisonInfo();schedule();}}
}
function emitSelectedGarrisonInfo(){const item=(mapMilitary.garrisons||[]).find(row=>Number(row.province_id)===Number(selected));window.dispatchEvent(new CustomEvent('map:garrison-info',{detail:item||null}));}
let militaryPreviewRevision=0;
async function requestMovementPreview(){
  const draft=militaryMoveDraft,revision=++militaryPreviewRevision;
  if(!draft)return;
  const route=[...draft.route];
  window.dispatchEvent(new CustomEvent('map:movement-progress',{detail:{route,formation:draft.formation,forecast:null}}));
  if(route.length<2)return;
  try{
    const last=route.at(-1),forecast=await militaryOrderApi('preview',Number(draft.formation.id),{route:route.map(point=>point.province_id),x:last.x,y:last.y});
    if(revision!==militaryPreviewRevision||militaryMoveDraft!==draft)return;
    window.dispatchEvent(new CustomEvent('map:movement-progress',{detail:{route,formation:draft.formation,forecast}}));
  }catch(error){
    if(revision!==militaryPreviewRevision||militaryMoveDraft!==draft)return;
    window.dispatchEvent(new CustomEvent('map:movement-progress',{detail:{route,formation:draft.formation,forecast:{error:error.message}}}));
  }
}
function scheduleMilitaryRefresh(){clearTimeout(militaryRefreshTimer);if(document.hidden)return;militaryRefreshTimer=setTimeout(async()=>{await refreshMapMilitary();scheduleMilitaryRefresh();},45000);}
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
  if(militaryChipPlacement){
    const placement=militaryChipPlacement,id=pickProvinceId(x,y);
    if(!isAdmin()&&Number(id)!==Number(placement.province_id)){status('Фишку можно перемещать только внутри её провинции.',3000);return;}
    const action=isAdmin()&&Number(id)!==Number(placement.province_id)?'admin_move':'place';
    void militaryOrderApi(action,Number(placement.id),{province_id:Number(id),x:p[0],y:p[1]}).then(()=>{militaryChipPlacement=null;status('Фишка перемещена.',2500);void refreshMapMilitary();}).catch(error=>status(error.message,5000));return;
  }
  if(militaryMoveDraft){
    const id=pickProvinceId(x,y),province=provinces.get(id),draft=militaryMoveDraft;
    if(!province||province.kind!==(draft.formation.domain==='naval'?'sea':'land')){status('Выберите провинцию нужного типа.',3000);return;}
    const previous=draft.route.at(-1);
    if(Number(previous.province_id)!==Number(id)&&!(provinceAdjacency[previous.province_id]||[]).includes(Number(id))){status('Выберите соседнюю провинцию.',3000);return;}
    const port=draft.formation.domain==='naval'?mapMarkers.find(marker=>marker.type==='port'&&Number(marker.province_id)===Number(id)):null;
    const point=port?{x:Number(port.x),y:Number(port.y)}:{x:p[0],y:p[1]};
    if(Number(previous.province_id)===Number(id))draft.route[draft.route.length-1]={...point,province_id:Number(id)};
    else draft.route.push({...point,province_id:Number(id)});
    void requestMovementPreview();schedule();return;
  }
  if(colonizationRouteMode){const id=pickProvinceId(x,y),province=provinces.get(id);if(!province){status('Нажмите внутри морской провинции.',2500);return;}window.dispatchEvent(new CustomEvent('colonization:route-province-picked',{detail:province}));return;}
  if(tradeRouteMode){const id=pickProvinceId(x,y),province=provinces.get(id);if(!province){status('Нажмите внутри провинции маршрута.',2500);return;}window.dispatchEvent(new CustomEvent('trade:route-province-picked',{detail:province}));return;}
  if(applicationPlacement){
    const id=pickProvinceId(x,y),province=provinces.get(id);
    if(!province||province.kind!=='land'){status('Выберите сухопутную провинцию',2500);return;}
    if(applicationPlacement.mode==='capital'&&!applicationPlacement.ids.includes(id)){status('Столица должна находиться в выбранной провинции',3000);return;}
    if(applicationPlacement.mode==='provinces'&&!province.layers?.trade){status('Нельзя выбрать провинцию без назначенной торговой зоны',3500);return;}
    if(applicationPlacement.mode==='provinces'&&(province.layers?.states||province.application_pending)){status('Провинция занята или зарезервирована',3000);return;}
    window.dispatchEvent(new CustomEvent('application:province-picked',{detail:{...province,x:p[0],y:p[1]}}));return;
  }
  if(portPlacement){
    const id=pickProvinceId(x,y);
    if(id!==Number(portPlacement.province_id)){status('Щёлкните внутри выбранной морской провинции',2500);return;}
    const placement=portPlacement;portPlacement=null;canvas.classList.remove('placing-marker');
    window.dispatchEvent(new CustomEvent('map:port-location-selected',{detail:{province_id:id,x:p[0],y:p[1],state_id:placement.state_id}}));
    status('Строю порт в выбранной точке…',0);return;
  }
  if(fortPlacement){
    const id=pickProvinceId(x,y);
    if(id!==Number(fortPlacement.province_id)){status('Щёлкните внутри выбранной сухопутной провинции',2500);return;}
    const placement=fortPlacement;fortPlacement=null;canvas.classList.remove('placing-marker');
    window.dispatchEvent(new CustomEvent('map:fort-location-selected',{detail:{province_id:id,x:p[0],y:p[1],state_id:placement.state_id,level:placement.level}}));
    return;
  }
  if(markerPlacement){
    const province_id=pickProvinceId(x,y);
    if(!province_id){status('Укажите точку внутри провинции',3000);return;}
    const draft=markerPlacement;markerPlacement=null;
    window.dispatchEvent(new CustomEvent('map:marker-location-selected',{detail:{...draft,province_id,x:p[0],y:p[1]}}));
    status('Сохраняю маркер…',2500);return;
  }
  const militaryHit=pickMilitary(x,y);
  if(militaryHit){
    selectedMarkerPopup=null;
    window.dispatchEvent(new Event('map:close-marker-popup'));
    window.dispatchEvent(new CustomEvent('map:military-selected',{detail:{...militaryHit.item,screenX:x,screenY:y}}));
    return;
  }
  const marker=pickMarker(x,y);
  if(marker&&canRenameMarker(marker)){selectedMarkerPopup=marker;window.dispatchEvent(new CustomEvent('map:marker-selected',{detail:{...marker,screenX:x,screenY:y}}));return;}
  selectedMarkerPopup=null;
  window.dispatchEvent(new CustomEvent('map:close-marker-popup'));
  const constructionHit=pickConstruction(x,y);
  if(constructionHit){window.dispatchEvent(new CustomEvent('map:military-selected',{detail:{...constructionHit.item,screenX:x,screenY:y}}));return;}
  window.dispatchEvent(new Event('map:close-military-popup'));
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
window.addEventListener('trade:route-pick',e=>{tradeRouteMode=Boolean(e.detail?.active);if(tradeRouteMode||e.detail?.clear)tradeRouteIds=[];if(tradeRouteMode)status('Выбор маршрута торговли: кликайте соседние провинции.',0);schedule();});
window.addEventListener('map:movement-start',event=>{
  const item=event.detail;if(!item||!['land','naval'].includes(item.domain)||!Number.isFinite(Number(item.x))||!Number.isFinite(Number(item.y)))return;
  if(item.domain==='naval'&&!item.is_port){status('Флотилия должна начать маршрут в доступном порту.',3500);return;}
  militaryMoveDraft={formation:item,route:[{x:Number(item.x),y:Number(item.y),province_id:Number(item.province_id)}]};
  void requestMovementPreview();status(item.domain==='naval'?'Коснитесь морских провинций по пути и завершите маршрут в доступном порту. Затем нажмите «Отправить приказ».':'Коснитесь суши, чтобы добавить точки маршрута. Затем нажмите «Отправить приказ».',0);schedule();
});
window.addEventListener('map:chip-place',event=>{militaryChipPlacement=event.detail;status(isAdmin()?'Выберите точку для фишки. Администратор может выбрать другую провинцию.':'Выберите точку внутри текущей провинции.',0);});
window.addEventListener('map:movement-clear',()=>{militaryPreviewRevision++;militaryMoveDraft=null;window.dispatchEvent(new CustomEvent('map:movement-progress',{detail:{route:[]}}));status('',0);schedule();});
window.addEventListener('map:movement-submit',()=>{if(!militaryMoveDraft||militaryMoveDraft.route.length<2){status('Добавьте хотя бы одну точку маршрута.',3000);return;}if(militaryMoveDraft.submitting)return;militaryMoveDraft.submitting=true;window.dispatchEvent(new CustomEvent('map:movement-ready',{detail:{formation:militaryMoveDraft.formation,route:militaryMoveDraft.route}}));schedule();});
window.addEventListener('map:movement-submit-failed',()=>{if(militaryMoveDraft)militaryMoveDraft.submitting=false;});
window.addEventListener('keydown',event=>{if(event.key==='Escape'&&militaryMoveDraft){militaryPreviewRevision++;militaryMoveDraft=null;window.dispatchEvent(new CustomEvent('map:movement-cancelled'));schedule();}else if(event.key==='Enter'&&militaryMoveDraft){event.preventDefault();window.dispatchEvent(new Event('map:movement-submit'));}});
window.addEventListener('trade:route-progress',e=>{tradeRouteIds=(e.detail?.ids||[]).slice(0,10).map(Number);schedule();});
window.addEventListener('colonization:route-pick',e=>{colonizationRouteMode=Boolean(e.detail?.active);if(e.detail?.clear||!colonizationRouteMode)colonizationRouteIds=[];if(colonizationRouteMode)status('Выбор морского маршрута: кликайте морские провинции по порядку.',0);schedule();});
window.addEventListener('colonization:route-progress',e=>{colonizationRouteIds=(e.detail?.ids||[]).slice(0,40).map(Number);schedule();});
window.addEventListener('keydown',e=>{if(e.key==='Escape'&&colonizationRouteMode){colonizationRouteMode=false;colonizationRouteIds=[];window.dispatchEvent(new CustomEvent('colonization:route-cancelled'));schedule();}else if(e.key==='Escape'&&tradeRouteMode){tradeRouteMode=false;window.dispatchEvent(new CustomEvent('trade:route-cancelled'));schedule();}});
function resize() {
  const oldW = Number(canvas.dataset.cssWidth)||viewportWidth, oldH = Number(canvas.dataset.cssHeight)||viewportHeight;
  const rect=canvas.getBoundingClientRect();
  viewportWidth=rect.width||window.innerWidth;viewportHeight=rect.height||window.innerHeight;
  const dpr = Math.min(devicePixelRatio || 1, 2);
  canvas.width = labels.width = Math.round(viewportWidth*dpr); canvas.height = labels.height = Math.round(viewportHeight*dpr);
  canvas.dataset.dpr = dpr;
  canvas.dataset.cssWidth=viewportWidth;canvas.dataset.cssHeight=viewportHeight;
  view.min = Math.min(viewportWidth/(region[2]-region[0]),viewportHeight/(region[3]-region[1]));
  if (ready) { view.x += (viewportWidth-oldW)/2; view.y += (viewportHeight-oldH)/2; clampView(); }
  schedule();
}
function clampView() {
  view.scale = Math.max(view.min, Math.min(view.max,view.scale));
  const clampAxis = (v,start,end,screen) => (end-start)*view.scale <= screen
    ? (screen-(start+end)*view.scale)/2
    : Math.max(screen-end*view.scale,Math.min(-start*view.scale,v));
  view.x = clampAxis(view.x,region[0],region[2],viewportWidth); view.y = clampAxis(view.y,region[1],region[3],viewportHeight);
}
function fit() {
  view.scale = view.min;
  view.x = (viewportWidth-(region[0]+region[2])*view.scale)/2;
  view.y = (viewportHeight-(region[1]+region[3])*view.scale)/2;
  clampView();schedule();
}
function zoom(factor,x=viewportWidth/2,y=viewportHeight/2) {
  if (!ready) return;
  const next = Math.max(view.min,Math.min(view.max,view.scale*factor));
  const ratio = next/view.scale; view.x = x-(x-view.x)*ratio; view.y = y-(y-view.y)*ratio; view.scale = next;
  clampView(); schedule();
}
function select(id, focus=false) {
  const p = provinces.get(id); if (!p) { status(`Провинция с ID ${id} не найдена в игровой области`,4000); return; }
  selected = id; $('selection').hidden = false;$('selection').classList.toggle('admin-edit',p.kind==='land'&&isAdminEditing()); $('selection-title').textContent = p.name;
  const relationLine=$('selection-relations');relationLine.replaceChildren();
  if(p.kind==='land'&&p.layers?.states?.id!=null){
    const appendState=(stateId,stateName,label)=>{const row=document.createElement('div');row.className='selection-state-link';const flag=document.createElement('span');flag.className='diplomacy-flag';flag.dataset.stateFlag=String(stateId);const category=categoryList.find(item=>item.layer==='states'&&Number(item.id)===Number(stateId));flag.style.setProperty('--state-color',category?.color||'#697264');row.append(flag);const link=document.createElement('button');link.type='button';link.textContent=`${label}: ${stateName}`;link.onclick=()=>window.dispatchEvent(new CustomEvent('ui:open-diplomacy-state',{detail:{stateId:Number(stateId)}}));row.append(link);relationLine.append(row);};
    appendState(p.layers.states.id,p.layers.states.name,'Владелец');
    if(p.occupation){const occupier=categoryList.find(item=>item.layer==='states'&&item.name.toLocaleLowerCase('ru-RU')===String(p.occupation).toLocaleLowerCase('ru-RU'));if(occupier&&Number(occupier.id)!==Number(p.layers.states.id))appendState(occupier.id,occupier.name,'Контролирует');}
    window.dispatchEvent(new CustomEvent('ui:hydrate-state-flags',{detail:{root:relationLine}}));
  }
  const details=$('selection-details');details.replaceChildren();
  const val=value=>value===null||value===undefined||value===''?'—':value;
  // Projections require state inputs supplied only to its controller.
  const occupiedByOther=p.occupation&&p.occupation!==p.layers?.states?.name;
  const canSeeEconomy=isAdmin()||(occupiedByOther?p.occupation_estate_tax_rates!=null:p.layers?.states?.estate_tax_rates!=null);
  const economy=canSeeEconomy?(provinceProjectionCache.get(id)||{}):{};
  const entries=p.kind==='sea'?[['ID',id],['Название',p.name],['Площадь',`${p.area.toLocaleString('ru-RU')} km²`],['Тип объекта','Море']]:[['ID',id],['Тип объекта',p.kind==='lake'?'Озеро':'Суша'],['Название',p.name],['Раса',p.layers?.races?.name],['Религия',p.layers?.religions?.name],['Государство',p.layers?.states?.name],['Оккупация',p.occupation],['Тип провинции',p.province_type],['Население',Number(p.population??0).toLocaleString('ru-RU')],['Прирост населения (расчёт)',economy.populationGrowth?.toLocaleString('ru-RU')],['Торговый статус',p.trade_status],['Ресурс',p.layers?.resources?.name],['Торговая зона',p.layers?.trade?.name],['Развитие',p.development],['Контроль',`${p.control??100}%`],['Налоги (расчёт)',economy.taxes],['Производство (расчёт)',economy.production],['Торговое влияние (расчёт)',economy.tradeInfluence],['Прирост рекрутов (расчёт)',economy.recruitGrowth],['Лимит рекрутов (расчёт)',economy.recruitLimit],['Ценность (расчёт)',economy.value??null],['Климат',p.layers?.climate?.name],['Площадь',`${p.area.toLocaleString('ru-RU')} km²`]];
  if(p.kind==='land')entries.splice(entries.length-1,0,['Местность',({forest:'Лес',marsh:'Болото',plains:'Равнины',hills:'Холмы',mountains:'Горы',high_mountains:'Высокие горы'})[p.terrain_type]]);
  const projectionFields={
    'Прирост населения (расчёт)':'populationGrowth','Налоги (расчёт)':'taxes',
    'Производство (расчёт)':'production','Торговое влияние (расчёт)':'tradeInfluence',
    'Прирост рекрутов (расчёт)':'recruitGrowth','Лимит рекрутов (расчёт)':'recruitLimit',
    'Ценность (расчёт)':'value',
  };
  for(const[label,value]of entries){const div=document.createElement('div');div.className='province-field';if(projectionFields[label])div.dataset.projectionKey=projectionFields[label];const name=document.createElement('span');name.textContent=`${label}: `;const content=document.createElement('strong');content.textContent=val(value);div.append(name,content);details.append(div);}
  if(p.kind==='land'&&canSeeEconomy&&!provinceProjectionCache.has(id)&&!provinceProjectionPending.has(id)){
    const request=provinceProjectionApi(id).then(result=>{
      if(String(result.data_revision)!==dataRevision||String(result.live_revision)!==liveRevision)return;
      provinceProjectionCache.set(id,result);
      if(selected!==id)return;
      details.querySelectorAll('[data-projection-key]').forEach(field=>{
        const value=result[field.dataset.projectionKey];
        field.querySelector('strong').textContent=value==null?'—':Number(value).toLocaleString('ru-RU');
      });
    }).catch(error=>{if(selected===id)status(error.message,4000);}).finally(()=>{if(provinceProjectionPending.get(id)===request)provinceProjectionPending.delete(id);});
    provinceProjectionPending.set(id,request);
  }
  if(p.kind==='land')for(const[group,label,layer,turnsField,targetField]of [['race','Расы','races','race_assimilation_turns','race_assimilation_target_id'],['religion','Религии','religions','religion_assimilation_turns','religion_assimilation_target_id']]){
    const turns=Number(p[turnsField]||0);if(turns<1)continue;
    const target=categoryList.find(category=>category.layer===layer&&Number(category.id)===Number(p[targetField]));
    const field=document.createElement('div');field.className='province-field province-assimilation-progress';
    field.textContent=`Ассимиляция ${label.toLocaleLowerCase('ru-RU')}: ${turns.toLocaleString('ru-RU')} ход. до ${target?.name||'официальной группы'}${p.occupation?' · на паузе из-за оккупации':''}`;details.append(field);
  }
  if(p.kind==='land'&&p.layers?.states?.id!=null&&(isAdmin()||canRenameProvince(p.layers.states.id))){const link=document.createElement('button');link.type='button';link.className='selection-open-data';link.textContent='Открыть в провинциях';link.onclick=()=>window.dispatchEvent(new CustomEvent('ui:open-province',{detail:{id:p.id,stateId:p.layers.states.id}}));details.append(link);}
  if(p.kind==='land'&&isAdminEditing())renderAdminEditor(p,details);
  else if(p.kind==='land'&&canRenameProvince(p.layers?.states?.id))renderNameEditor(p,details);
  window.dispatchEvent(new CustomEvent('map:selection-changed',{detail:p}));
  emitSelectedGarrisonInfo();
  if($('province-id'))$('province-id').value = id;
  if (focus) {
    const [bx0,by0,bx1,by1] = p.bbox;
    const [x0,y0,x1,y1] = [Math.max(bx0,region[0]),Math.max(by0,region[1]),Math.min(bx1,region[2]-1),Math.min(by1,region[3]-1)];
    const panelSpace = viewportWidth > 600 ? 340 : 128;
    view.scale = Math.max(view.min,Math.min(view.max, (viewportWidth-panelSpace)/Math.max(x1-x0+1,40)*.65, viewportHeight/Math.max(y1-y0+1,40)*.65));
    view.x = (viewportWidth+(viewportWidth > 600 ? 290 : 0))/2 - (x0+x1)/2*view.scale;
    view.y = viewportHeight/2 - (y0+y1)/2*view.scale;
    clampView();
  }
  schedule();
}

function renderAdminEditor(p,host){
  const form=document.createElement('form');form.id='province-admin-form';form.className='province-editor';
  const categories=categoryList;
  const choice=(name,title,layer)=>`<label class="field"><span>${title}</span><select name="${name}"><option value="">—</option>${categories.filter(c=>c.layer===layer).map(c=>`<option value="${html(c.name)}" ${p.layers?.[layer]?.id===c.id?'selected':''}>${html(c.name)}</option>`).join('')}</select></label>`;
  form.innerHTML=`<div class="editor-grid"><label class="field"><span>Название</span><input name="name" value="${html(p.name)}" maxlength="120" required></label>${choice('race','Раса','races')}${choice('religion','Религия','religions')}<label class="field"><span>Государство</span><input name="state" list="state-options" value="${html(p.layers?.states?.name||'')}" data-original="${html(p.layers?.states?.name||'')}"><datalist id="state-options">${categories.filter(c=>c.layer==='states').map(c=>`<option value="${html(c.name)}">`).join('')}</datalist></label><label class="field"><span>Оккупация</span><select name="occupation"><option value="">— нет —</option>${categories.filter(c=>c.layer==='states').map(c=>`<option value="${html(c.name)}" ${p.occupation===c.name?'selected':''}>${html(c.name)}</option>`).join('')}</select></label><label class="field"><span>Тип провинции</span><input value="${html(p.province_type||'Регион')}" readonly></label><label class="field"><span>Население</span><input name="population" type="number" min="0" max="2000000000" step="1" value="${p.population??0}"></label><label class="field"><span>Контроль, %</span><input name="control" type="number" min="0" max="100" step="1" value="${p.control??100}" required></label><label class="field"><span>Торговый статус</span><select name="trade_status">${['Отсутствует','Устье реки','Природный порт','Центр торговли I','Центр торговли II','Центр торговли III'].map(value=>`<option value="${value}" ${(p.trade_status||'Отсутствует')===value?'selected':''}>${value}</option>`).join('')}</select></label>${choice('resource','Ресурс','resources')}${choice('trade','Торговая зона','trade')}<label class="field"><span>Развитие</span><input name="development" type="number" min="0" step="1" value="${p.development??''}"></label>${choice('climate','Климат','climate')}<label class="field"><span>Тип местности</span><select name="terrain_type"><option value="">— нет —</option><option value="forest" ${p.terrain_type==='forest'?'selected':''}>Лес</option><option value="marsh" ${p.terrain_type==='marsh'?'selected':''}>Болото</option></select></label><label class="check-row"><span>Маркер: Столица</span><input name="capital" type="checkbox" data-original="${p.has_capital_marker?'true':'false'}" ${p.has_capital_marker?'checked':''}></label><label class="check-row"><span>Маркер: Город</span><input name="city" type="checkbox" data-original="${p.has_city_marker?'true':'false'}" ${p.has_city_marker?'checked':''}></label></div><p class="hint">Тип определяется маркерами; после колонизации без маркеров устанавливается Регион.</p><button class="primary" type="submit">Сохранить изменения</button>`;
  const terrainOptions=[['plains','Равнины'],['hills','Холмы'],['mountains','Горы'],['high_mountains','Высокие горы']];for(const [value,label] of terrainOptions)form.elements.terrain_type.add(new Option(label,value));form.elements.terrain_type.value=p.terrain_type||'';
  host.append(form);
  form.onsubmit=async event=>{event.preventDefault();const data=new FormData(form),payload={};for(const key of ['name','race','religion','resource','trade','climate'])payload[key]=data.get(key)||null;payload.control=Number(data.get('control'));payload.occupation=data.get('occupation')||null;payload.terrain_type=data.get('terrain_type')||null;payload.trade_status=data.get('trade_status');payload.population=Number(data.get('population'));const stateInput=form.elements.state;if(stateInput.value.trim()!==stateInput.dataset.original)payload.state=stateInput.value.trim()||null;payload.development=data.get('development')===''?null:Number(data.get('development'));for(const key of ['capital','city']){const input=form.elements[key];if(input.checked!==(input.dataset.original==='true'))payload[key]=input.checked;}const button=form.querySelector('button');button.disabled=true;try{const result=await api(`admin/provinces/${p.id}`,{method:'PATCH',body:JSON.stringify(payload)});window.dispatchEvent(new CustomEvent('province:updated',{detail:result}));}catch(error){button.disabled=false;status(error.message,4000);}};
  const assimilationForm=document.createElement('form');assimilationForm.className='province-editor province-assimilation-editor';assimilationForm.innerHTML=`<h4>Ассимиляция</h4><p class="hint">Сроки задаются отдельно для расы и религии. 0 — автоматически по статусу группы; ручное значение — от 1 до 300 ходов.</p><div class="editor-grid"><label class="field"><span>Осталось ходов: раса</span><input name="race_turns" type="number" min="0" max="300" step="1" value="${Number(p.race_assimilation_turns||0)}"></label><label class="field"><span>Осталось ходов: религия</span><input name="religion_turns" type="number" min="0" max="300" step="1" value="${Number(p.religion_assimilation_turns||0)}"></label></div><button class="primary" type="submit">Сохранить сроки</button>`;
  host.append(assimilationForm);
  assimilationForm.onsubmit=async event=>{event.preventDefault();const data=new FormData(assimilationForm),button=assimilationForm.querySelector('button');button.disabled=true;try{await api(`admin/provinces/${p.id}/assimilation`,{method:'PATCH',body:JSON.stringify({race_turns:Number(data.get('race_turns')),religion_turns:Number(data.get('religion_turns'))})});window.dispatchEvent(new Event('map:refresh'));status('Сроки ассимиляции сохранены',3000);}catch(error){button.disabled=false;status(error.message,4000);}};
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
function pickMarker(x,y){
  let nearest=null,nearestDistance=Infinity;
  for(const marker of mapMarkers){
    if(!activeSettings.markers?.[marker.type]||!Number.isFinite(marker.x)||!Number.isFinite(marker.y))continue;
    const size=(MARKER_HEIGHT[marker.type]||10)*view.scale,image=markerIcons[marker.type];
    const ratio=image?.naturalWidth&&image?.naturalHeight?image.naturalWidth/image.naturalHeight:1;
    const dx=x-(marker.x*view.scale+view.x),dy=y-(marker.y*view.scale+view.y);
    if(Math.abs(dx)<=Math.max(7,size*ratio/2)&&Math.abs(dy)<=Math.max(7,size/2)){
      const distance=dx*dx+dy*dy;if(distance<nearestDistance){nearest=marker;nearestDistance=distance;}
    }
  }
  return nearest;
}
let markerMoveDraft=null,markerDragPointer=null;
function previewMarkerPosition(x,y){
  if(!markerMoveDraft)return;
  markerMoveDraft.x=x;markerMoveDraft.y=y;
  mapMarkers=mapMarkers.map(marker=>Number(marker.id)===markerMoveDraft.id?{...marker,x,y}:marker);
  window.dispatchEvent(new CustomEvent('map:marker-move-preview',{detail:{id:markerMoveDraft.id,x,y}}));schedule();
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
  if(markerMoveDraft&&Number(pickMarker(e.clientX,e.clientY)?.id)===markerMoveDraft.id){
    markerDragPointer=e.pointerId;canvas.setPointerCapture(e.pointerId);canvas.classList.add('dragging-marker');return;
  }
  window.dispatchEvent(new Event('map:close-military-popup'));
  canvas.setPointerCapture(e.pointerId); pointers.set(e.pointerId,{x:e.clientX,y:e.clientY});
  if(pointers.size===1)moved=false; else moved=true;
  snapshotGesture(); canvas.classList.add('dragging');
});
canvas.addEventListener('pointermove',e => {
  if(markerDragPointer===e.pointerId&&markerMoveDraft){
    if(Number(pickProvinceId(e.clientX,e.clientY))===markerMoveDraft.province_id){previewMarkerPosition((e.clientX-view.x)/view.scale,(e.clientY-view.y)/view.scale);}
    return;
  }
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
  if(markerDragPointer===e.pointerId){markerDragPointer=null;canvas.classList.remove('dragging-marker');return;}
  if(!pointers.has(e.pointerId))return;
  const click=!moved&&pointers.size===1&&e.type==='pointerup'; pointers.delete(e.pointerId);
  if(!pointers.size)canvas.classList.remove('dragging');
  snapshotGesture(); if(click)mapClick(e.clientX,e.clientY);
}
canvas.addEventListener('pointerup',endPointer); canvas.addEventListener('pointercancel',endPointer);
canvas.addEventListener('wheel',e=>{ e.preventDefault();window.dispatchEvent(new Event('map:close-military-popup'));zoom(Math.exp(-e.deltaY*(e.deltaMode===1?.045:.0015)),e.clientX,e.clientY); },{passive:false});
canvas.addEventListener('dblclick',e=>{e.preventDefault();if(toolMode==='area')finishArea();else if(!toolMode)zoom(2,e.clientX,e.clientY);});
window.addEventListener('map:settings',e=>{activeSettings=e.detail;showIds=!!e.detail.showIds;if(ready)updateLayerColors();schedule();});
window.addEventListener('auth:user-changed',()=>{void refreshMapMilitary();scheduleMilitaryRefresh();});
window.addEventListener('map:refreshed',()=>{void refreshMapMilitary();});
window.addEventListener('map:refresh',()=>{void refreshMapMilitary();});
window.addEventListener('state:resources-changed',()=>provinceProjectionCache.clear());
document.addEventListener('visibilitychange',()=>{if(document.hidden)clearTimeout(militaryRefreshTimer);else{void refreshMapMilitary();scheduleMilitaryRefresh();}});
window.addEventListener('admin:editing',()=>{if(selected)select(selected);});
window.addEventListener('map:admin-paint',e=>{adminPaint=e.detail||null;if(adminPaint)status('Нанесение включено: нажимайте на сухопутные провинции',3000);});
let markerPlacement=null;
window.addEventListener('map:place-marker',e=>{markerPlacement=e.detail||null;canvas.classList.toggle('placing-marker',!!markerPlacement);if(markerPlacement)status('Щёлкните по точке провинции для размещения маркера',0);else status('',0);});
window.addEventListener('map:marker-move-start',e=>{
  const marker=e.detail;if(!isAdmin()||!marker)return;
  markerMoveDraft={id:Number(marker.id),province_id:Number(marker.province_id),original_x:Number(marker.x),original_y:Number(marker.y),x:Number(marker.x),y:Number(marker.y)};
  selectedMarkerPopup=null;canvas.classList.add('moving-marker');status('Зажмите маркер и перетащите его внутри той же провинции. Затем нажмите «Сохранить».',0);
});
window.addEventListener('map:marker-move-cancel',()=>{
  if(!markerMoveDraft)return;
  previewMarkerPosition(markerMoveDraft.original_x,markerMoveDraft.original_y);
  markerMoveDraft=null;markerDragPointer=null;canvas.classList.remove('moving-marker','dragging-marker');status('Перемещение маркера отменено',2500);
});
window.addEventListener('map:marker-move-saved',e=>{
  const marker=e.detail;if(marker)mapMarkers=mapMarkers.map(item=>Number(item.id)===Number(marker.id)?{...item,...marker}:item);
  markerMoveDraft=null;markerDragPointer=null;canvas.classList.remove('moving-marker','dragging-marker');schedule();
});
window.addEventListener('map:place-port',e=>{portPlacement=e.detail||null;canvas.classList.toggle('placing-marker',!!portPlacement);if(portPlacement)status('Щёлкните по точке внутри выбранной морской провинции · Esc — отмена',0);else status('',0);});
window.addEventListener('map:place-fort',e=>{fortPlacement=e.detail||null;canvas.classList.toggle('placing-marker',!!fortPlacement);if(fortPlacement)status('Выберите точку крепости внутри провинции · Esc — отмена',0);else status('',0);});
window.addEventListener('keydown',e=>{if(e.key==='Escape'&&portPlacement){portPlacement=null;canvas.classList.remove('placing-marker');window.dispatchEvent(new Event('map:port-placement-cancelled'));status('Размещение порта отменено',2500);}if(e.key==='Escape'&&fortPlacement){fortPlacement=null;canvas.classList.remove('placing-marker');window.dispatchEvent(new Event('map:fort-placement-cancelled'));status('Размещение крепости отменено',2500);}});
window.addEventListener('application:pick',e=>{applicationPlacement=e.detail||null;status(applicationPlacement?.mode==='provinces'?'Выберите пять свободных сухопутных провинций':applicationPlacement?.mode==='capital'?'Выберите провинцию столицы':'',0);if(e.detail?.mode==='provinces'){applicationSelectedIds=new Set((e.detail.ids||[]).map(Number));if(ready)updateLayerColors();schedule();}});
window.addEventListener('application:selection-updated',e=>{applicationSelectedIds=new Set((e.detail?.ids||[]).map(Number));if(ready)updateLayerColors();schedule();});
window.addEventListener('application:clear-selection',()=>{applicationSelectedIds.clear();if(ready)updateLayerColors();schedule();});
window.addEventListener('province:updated',e=>{const p=e.detail;provinces.set(p.id,{...provinces.get(p.id),...p});thematicComponents.clear();for(const[layer,category]of Object.entries(p.layers||{}))if(!categoryList.some(c=>c.layer===layer&&c.id===category.id))categoryList.push({layer,...category});if(selected===p.id)select(p.id);updateLayerColors();updateTerrainTypes();schedule();});
function installMapData(data){
  const nextTileRevision=String(data.tile_revision||0),nextRegion=data.region||region,regionChanged=JSON.stringify(nextRegion)!==JSON.stringify(region),tileChanged=nextTileRevision!==tileRevision;
  tileRevision=nextTileRevision;dataRevision=String(data.data_revision||0);liveRevision=String(data.live_revision||liveRevision);region=nextRegion;
  regionSlots=(Math.ceil(region[2]/tileSize)-Math.floor(region[0]/tileSize))*(Math.ceil(region[3]/tileSize)-Math.floor(region[1]/tileSize));
  if(ready&&(tileChanged||regionChanged))resetTileCache(Math.min(regionSlots,view.scale>view.min*1.8?12:25));
  categoryList=data.categories;mapMarkers=data.markers||[];mapColonies=data.colonies||[];mapTradeRoutes=data.trade_routes||[];provinces=new Map(data.provinces.map(p=>[p.id,{...p,rgb:p.id}]));provinceAdjacency=data.adjacency||{};provinceProjectionCache.clear();provinceProjectionPending.clear();thematicComponents.clear();
  window.dispatchEvent(new CustomEvent('map:refreshed',{detail:data}));if(selected&&!provinces.has(selected))selected=0;if(selected)select(selected);updateLayerColors();updateTerrainTypes();updateFogVisibility();schedule();
}
window.addEventListener('map:cache-update',e=>{if(ready)installMapData(e.detail);});
window.addEventListener('map:cache-error',e=>status(e.detail?.message||'Не удалось обновить карту с сервера',4000));
window.addEventListener('map:refresh',async()=>{try{installMapData(await api('map'));}catch(error){status(error.message,5000);}});
async function syncMapInBackground(){
  clearTimeout(syncTimer);
  if(!ready||document.hidden||syncInProgress||window.FAUXLORE_CONFIG?.backend!=='supabase'){
    if(ready&&window.FAUXLORE_CONFIG?.backend==='supabase')syncTimer=setTimeout(syncMapInBackground,60000);
    return;
  }
  syncInProgress=true;
  try{
    const revision=await api('map/revision'),nextData=String(revision.data_revision||0),nextLive=String(revision.live_revision||0),nextTiles=String(revision.tile_revision||'');
    if(nextData!==dataRevision||nextLive!==liveRevision||nextTiles!==tileRevision){
      const data=await api('map');
      liveRevision=nextLive;
      installMapData(data);
    }
  }catch(error){console.debug('Фоновое обновление карты не выполнено:',error.message);}
  finally{syncInProgress=false;if(ready&&window.FAUXLORE_CONFIG?.backend==='supabase')syncTimer=setTimeout(syncMapInBackground,60000);}
}
document.addEventListener('visibilitychange',()=>{if(document.hidden)clearTimeout(syncTimer);else void syncMapInBackground();});
window.addEventListener('focus',()=>{if(!document.hidden)void syncMapInBackground();});
window.addEventListener('map:marker-created',e=>{mapMarkers.push(e.detail);schedule();});
window.addEventListener('map:marker-renamed',e=>{const marker=e.detail;if(!marker)return;mapMarkers=mapMarkers.map(item=>Number(item.id)===Number(marker.id)?{...item,...marker}:item);if(Number(selectedMarkerPopup?.id)===Number(marker.id))selectedMarkerPopup={...selectedMarkerPopup,...marker};schedule();});
window.addEventListener('map:refreshed',()=>{if(markerMoveDraft)mapMarkers=mapMarkers.map(item=>Number(item.id)===markerMoveDraft.id?{...item,x:markerMoveDraft.x,y:markerMoveDraft.y}:item);schedule();});
window.addEventListener('map:marker-deleted',e=>{mapMarkers=mapMarkers.filter(marker=>marker.id!==e.detail);if(selectedMarkerPopup?.id===e.detail)selectedMarkerPopup=null;schedule();});
window.addEventListener('map:close-marker-popup',()=>{selectedMarkerPopup=null;});
window.addEventListener('province:renamed',e=>{const p=provinces.get(e.detail.id);if(p){p.name=e.detail.name;if(selected===p.id)select(p.id);schedule();}});
window.addEventListener('map:search',e=>{if(ready)select(e.detail,true);});
window.addEventListener('map:tool',e=>{toolMode=e.detail;toolPoints=[];areaClosed=false;canvas.classList.toggle('measuring',!!toolMode);toolResult(toolMode?'Нажмите на карту':'Выберите инструмент');schedule();});
window.addEventListener('map:finish',finishArea);
window.addEventListener('map:undo',()=>{toolPoints.pop();areaClosed=false;toolResult(`Точек: ${toolPoints.length}`);schedule();});
window.addEventListener('map:clear-tool',()=>{toolPoints=[];areaClosed=false;toolResult('Измерение очищено');schedule();});
window.addEventListener('map:coordinate',e=>{const[x,y]=e.detail;if(x<region[0]||x>=region[2]||y<region[1]||y>=region[3]){status('Точка находится вне игровой области',4000);return;}view.scale=Math.max(view.scale,1);view.x=viewportWidth/2-x*view.scale;view.y=viewportHeight/2-y*view.scale;clampView();schedule();});
window.addEventListener('map:copy-coordinates',async()=>{if(!lastPoint){status('Сначала выберите точку на карте',3000);return;}try{await navigator.clipboard.writeText(lastPoint.map(v=>v.toFixed(2)).join(', '));status('Координаты скопированы',2500);}catch{status('Не удалось скопировать координаты',3000);}});
$('clear-selection').onclick=()=>{selected=0;$('selection').hidden=true;window.dispatchEvent(new CustomEvent('map:selection-changed',{detail:null}));window.dispatchEvent(new CustomEvent('map:garrison-info',{detail:null}));schedule();};
window.addEventListener('resize',resize);
window.visualViewport?.addEventListener('resize',resize);
canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();ready=false;status('Графический контекст потерян. Перезагрузите страницу.');});
async function init() {
  if(!gl)throw new Error('Для просмотра карты требуется браузер с WebGL 2.');
  const data=await loadInitialMap();region=data.region;tileRevision=String(data.tile_revision||0);dataRevision=String(data.data_revision||0);liveRevision=String(data.live_revision||0);categoryList=data.categories;mapMarkers=data.markers||[];mapColonies=data.colonies||[];mapTradeRoutes=data.trade_routes||[];provinceAdjacency=data.adjacency||{};
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
  void api('map/revision').then(revision=>{if(String(revision.data_revision||0)!==dataRevision||String(revision.live_revision||0)!==liveRevision||String(revision.tile_revision||'')!==tileRevision)void syncMapInBackground();}).catch(error=>console.debug('Не удалось проверить версию карты:',error.message));
  syncTimer=setTimeout(syncMapInBackground,60000);
}
init().catch(error=>{console.error(error);status(error.message);});
