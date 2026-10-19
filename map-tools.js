// 1px² = 1km², hence the side of one source pixel is 1km.
export const distance = (a,b) => Math.hypot(b[0]-a[0],b[1]-a[1]);
export function polygonArea(points) {
  return Math.abs(points.reduce((sum,p,i) => { const q=points[(i+1)%points.length]; return sum+p[0]*q[1]-q[0]*p[1]; },0))/2;
}
export function segmentsIntersect(a,b,c,d) {
  const cross=(p,q,r)=>(q[0]-p[0])*(r[1]-p[1])-(q[1]-p[1])*(r[0]-p[0]);
  const on=(p,q,r)=>Math.abs(cross(p,q,r))<1e-8&&r[0]>=Math.min(p[0],q[0])&&r[0]<=Math.max(p[0],q[0])&&r[1]>=Math.min(p[1],q[1])&&r[1]<=Math.max(p[1],q[1]);
  return cross(a,b,c)*cross(a,b,d)<0&&cross(c,d,a)*cross(c,d,b)<0||on(a,b,c)||on(a,b,d)||on(c,d,a)||on(c,d,b);
}
export function simplePolygon(points) {
  if(points.length<3)return false;
  for(let i=0;i<points.length;i++)for(let j=i+1;j<points.length;j++){
    if(j===i+1||i===0&&j===points.length-1)continue;
    if(segmentsIntersect(points[i],points[(i+1)%points.length],points[j],points[(j+1)%points.length]))return false;
  }
  return polygonArea(points)>0;
}
export function niceLength(length) {
  const base=10**Math.floor(Math.log10(Math.max(length,1e-9)));
  return [5,2,1].map(x=>x*base).find(x=>x<=length)||base/2;
}
