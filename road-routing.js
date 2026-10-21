// Pure routing core: exact 4-connected mask, safe simplification and constrained curves.
export function lineInside(a,b,inside){
  const steps=Math.ceil(Math.hypot(b[0]-a[0],b[1]-a[1])*4);
  for(let i=0;i<=steps;i++){
    const t=steps?i/steps:0,x=a[0]+(b[0]-a[0])*t,y=a[1]+(b[1]-a[1])*t;
    if(!inside(x,y))return false;
    // A stroke must not cut diagonally across a forbidden corner.
    if(i){const pt=(i-1)/steps,px=a[0]+(b[0]-a[0])*pt,py=a[1]+(b[1]-a[1])*pt;
      if(Math.floor(px)!==Math.floor(x)&&Math.floor(py)!==Math.floor(y)&&(!inside(px,y)||!inside(x,py)))return false;}
  }
  return true;
}
class Heap{
  data=[];
  push(value){const a=this.data;let i=a.length;a.push(value);while(i){const p=(i-1)>>1;if(a[p][1]<=value[1])break;a[i]=a[p];i=p;}a[i]=value;}
  pop(){const a=this.data,first=a[0],last=a.pop();if(a.length){let i=0;while(2*i+1<a.length){let j=2*i+1;if(j+1<a.length&&a[j+1][1]<a[j][1])j++;if(a[j][1]>=last[1])break;a[i]=a[j];i=j;}a[i]=last;}return first;}
}
export function routeOnMask({width,height,mask,start,end,origin=[0,0]}){
  const inside=(x,y)=>{x=Math.floor(x-origin[0]);y=Math.floor(y-origin[1]);return x>=0&&y>=0&&x<width&&y<height&&mask[y*width+x]===1;};
  if(!inside(...start)||!inside(...end))throw Error('Центр или маркер находится вне своей провинции. Выберите другую точку привязки.');
  const index=p=>Math.floor(p[1]-origin[1])*width+Math.floor(p[0]-origin[0]);
  const first=index(start),last=index(end),size=width*height;
  const g=new Float32Array(size);g.fill(Infinity);g[first]=0;
  const parent=new Int32Array(size);parent.fill(-1);const closed=new Uint8Array(size),heap=new Heap();
  const goalX=last%width,goalY=Math.floor(last/width),heuristic=i=>Math.abs(i%width-goalX)+Math.abs(Math.floor(i/width)-goalY);
  heap.push([first,heuristic(first)]);
  while(heap.data.length){
    const [i]=heap.pop();if(closed[i])continue;if(i===last)break;closed[i]=1;
    const x=i%width,y=Math.floor(i/width);
    for(const n of [x?i-1:-1,x+1<width?i+1:-1,y?i-width:-1,y+1<height?i+width:-1]){
      if(n<0||!mask[n]||closed[n])continue;
      const nx=n%width,ny=Math.floor(n/width);
      const edge=nx===0||ny===0||nx===width-1||ny===height-1||!mask[n-1]||!mask[n+1]||!mask[n-width]||!mask[n+width];
      const cost=g[i]+1+(edge?2:0);if(cost>=g[n])continue;
      g[n]=cost;parent[n]=i;heap.push([n,cost+heuristic(n)]);
    }
  }
  if(first!==last&&parent[last]<0)throw Error('Нет прохода внутри выбранных провинций. Добавьте промежуточную провинцию или выберите другой маркер.');
  const path=[];for(let i=last;i!==-1;i=parent[i]){path.push([i%width+origin[0]+.5,Math.floor(i/width)+origin[1]+.5]);if(i===first)break;}
  path.reverse();path[0]=start;path.push(end);
  // Keep control points at intervals: a perfectly straight shortcut is not a road curve.
  const simple=[path[0]];
  for(let i=0;i<path.length-1;){let j=Math.min(path.length-1,i+24);while(j>i+1&&!lineInside(path[i],path[j],inside))j--;simple.push(path[j]);i=j;}
  // Bow each internal point only when both adjacent segments remain inside the mask.
  for(let i=1;i<simple.length-1;i++){
    const prev=simple[i-1],next=simple[i+1],p=simple[i],dx=next[0]-prev[0],dy=next[1]-prev[1],len=Math.hypot(dx,dy)||1;
    for(let amplitude=5;amplitude>=1;amplitude/=2){
      const shift=amplitude*Math.sin(i*.8),q=[p[0]-dy/len*shift,p[1]+dx/len*shift];
      if(lineInside(prev,q,inside)&&lineInside(q,next,inside)){simple[i]=q;break;}
    }
  }
  let smooth=simple;
  for(let pass=0;pass<2;pass++){
    const next=[smooth[0]];
    for(let i=1;i<smooth.length-1;i++){
      const a=smooth[i-1],p=smooth[i],b=smooth[i+1],q=[p[0]*.75+a[0]*.25,p[1]*.75+a[1]*.25],r=[p[0]*.75+b[0]*.25,p[1]*.75+b[1]*.25];
      if(lineInside(next[next.length-1],q,inside)&&lineInside(q,r,inside)&&lineInside(r,b,inside))next.push(q,r);else next.push(p);
    }
    next.push(smooth[smooth.length-1]);smooth=next;
  }
  if(!smooth.every((p,i)=>!i||lineInside(smooth[i-1],p,inside)))throw Error('Не удалось построить безопасный изгиб дороги');
  return smooth;
}
