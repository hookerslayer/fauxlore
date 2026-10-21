import {routeOnMask} from './road-routing.js';
const SIZE=512,tiles=new Map();let revision='';
async function tile(x,y,rev){
  const key=`${x}_${y}`;
  if(tiles.has(key)){const value=tiles.get(key);tiles.delete(key);tiles.set(key,value);return value;}
  const response=await fetch(`map-data/road-tiles/${key}.bin.gz?v=${encodeURIComponent(rev)}`);
  if(!response.ok)throw Error('Не найдена маска для дорог. Пересоберите routing tiles.');
  const bytes=await response.arrayBuffer();
  // Some hosts transparently decompress gzip; accept either representation.
  const buffer=bytes.byteLength===SIZE*SIZE*2?bytes:await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  if(buffer.byteLength!==SIZE*SIZE*2)throw Error('Повреждена маска дорог');
  const value=new Uint16Array(buffer);tiles.set(key,value);if(tiles.size>16)tiles.delete(tiles.keys().next().value);return value;
}
self.onmessage=async({data})=>{
  const {id,a,b,bbox,region,tileRevision}=data;
  try{
    if(revision!==tileRevision){tiles.clear();revision=tileRevision;}
    const left=Math.max(region[0],Math.floor(bbox[0])),top=Math.max(region[1],Math.floor(bbox[1])),right=Math.min(region[2],Math.ceil(bbox[2])),bottom=Math.min(region[3],Math.ceil(bbox[3]));
    const width=right-left,height=bottom-top;
    if(width<=0||height<=0||width*height>2500000)throw Error('Слишком большой участок. Добавьте промежуточную провинцию.');
    const mask=new Uint8Array(width*height);
    for(let ty=Math.floor(top/SIZE);ty<=Math.floor((bottom-1)/SIZE);ty++)for(let tx=Math.floor(left/SIZE);tx<=Math.floor((right-1)/SIZE);tx++){
      const pixels=await tile(tx,ty,tileRevision);
      for(let y=Math.max(top,ty*SIZE);y<Math.min(bottom,(ty+1)*SIZE);y++)for(let x=Math.max(left,tx*SIZE);x<Math.min(right,(tx+1)*SIZE);x++){
        const province=pixels[(y-ty*SIZE)*SIZE+x-tx*SIZE];
        if(province===a.province_id||province===b.province_id)mask[(y-top)*width+x-left]=1;
      }
    }
    // One source-pixel clearance keeps the entire stroke (max width 1px)
    // inside the union, not only its mathematical centerline.
    const safe=mask.slice();
    for(let y=0;y<height;y++)for(let x=0;x<width;x++){
      if(!mask[y*width+x])continue;
      if(!x||!y||x===width-1||y===height-1){safe[y*width+x]=0;continue;}
      for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++)if(!mask[(y+dy)*width+x+dx])safe[y*width+x]=0;
    }
    const points=routeOnMask({width,height,mask:safe,start:[a.x,a.y],end:[b.x,b.y],origin:[left,top]});
    self.postMessage({id,points});
  }catch(error){self.postMessage({id,error:error.message});}
};
