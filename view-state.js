const pendingHeights=new WeakMap();
/** Preserve expanded sections and scroll position while replacing a state view. */
export function refreshStateView(host,render){
  const details=[...host.querySelectorAll('details')].map(item=>item.open);
  const inner=[...host.querySelectorAll('.table-scroll')].map(item=>({top:item.scrollTop,left:item.scrollLeft}));
  const ancestors=[];
  for(let node=host.parentElement;node;node=node.parentElement)ancestors.push({node,top:node.scrollTop,left:node.scrollLeft});
  const focusSelector='button,a,input,select,textarea,summary,[tabindex]';
  const focusIndex=[...host.querySelectorAll(focusSelector)].indexOf(document.activeElement);
  const previous=pendingHeights.get(host);if(previous)clearTimeout(previous.timer);
  const minHeight=previous?.original??host.style.minHeight,previousHeight=host.getBoundingClientRect().height;
  host.style.minHeight=`${previousHeight}px`;
  render();
  [...host.querySelectorAll('details')].forEach((item,index)=>{if(index<details.length)item.open=details[index];});
  [...host.querySelectorAll('.table-scroll')].forEach((item,index)=>{if(inner[index]){item.scrollTop=inner[index].top;item.scrollLeft=inner[index].left;}});
  if(focusIndex>=0)[...host.querySelectorAll(focusSelector)][focusIndex]?.focus({preventScroll:true});
  for(const {node,top,left} of ancestors){node.scrollTop=top;node.scrollLeft=left;}
  requestAnimationFrame(()=>{for(const {node,top,left} of ancestors){if(node.isConnected&&node.scrollTop===0&&top>0){node.scrollTop=top;node.scrollLeft=left;}}});
  const timer=setTimeout(()=>{host.style.minHeight=minHeight;pendingHeights.delete(host);},5000);
  pendingHeights.set(host,{original:minHeight,timer});
}
