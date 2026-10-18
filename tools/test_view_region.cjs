// Exercise the real camera and tile-range functions without a GPU.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('viewer.js', 'utf8');
const region = JSON.parse(fs.readFileSync('map-data/view-region.json', 'utf8')).bounds;
const functions = ['tileRange','clampView','fit'].map(name => {
  const start=source.indexOf(`function ${name}(`);
  const end=source.indexOf('\n}',start)+2;
  return source.slice(start,end);
}).join('\n');
for(const [w,h] of [[1920,1080],[424,900],[1000,1000]]) {
  const context = {region,innerWidth:w,innerHeight:h,tileSize:2048,
    view:{x:0,y:0,scale:1,min:Math.min(w/(region[2]-region[0]),h/(region[3]-region[1])),max:12},
    schedule(){}};
  vm.createContext(context);
  vm.runInContext(functions+';fit();',context);
  assert.equal(vm.runInContext('tileRange().length',context),4);
  for(const offset of [-1e7,1e7]) {
    context.view.scale=2;context.view.x=offset;context.view.y=offset;
    vm.runInContext('clampView()',context);
    const v=context.view;
    assert.ok(v.x<=-region[0]*v.scale+1e-6);
    assert.ok(v.x>=w-region[2]*v.scale-1e-6);
    assert.ok(v.y<=-region[1]*v.scale+1e-6);
    assert.ok(v.y>=h-region[3]*v.scale-1e-6);
    const tiles=vm.runInContext('tileRange()',context);
    assert.ok(tiles.every(([x,y])=>x>=1&&x<=2&&y>=1&&y<=2));
  }
}
console.log('PASS: regional fit, pan bounds and tile limits on desktop/mobile');
