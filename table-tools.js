// Сортировка и фильтрация таблиц: клиентские помощники без серверной логики.
export function makeSortable(table){
  if(!table?.tHead?.rows?.length)return;
  const head=table.tHead.rows[0];
  [...head.cells].forEach((cell,index)=>{
    if(cell.dataset.nosort!==undefined)return;
    cell.classList.add('table-sortable');
    cell.tabIndex=0;
    cell.setAttribute('role','button');
    const toggle=()=>sortBy(table,index,cell);
    cell.addEventListener('click',toggle);
    cell.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();toggle();}});
  });
}

function cellNumber(cell){
  const text=String(cell?.innerText||'').trim();
  const normalized=text.replace(/\s+/g,'').replace(/[−–]/g,'-').replace(/%/g,'').replace(/G|ОП|п\.п\.|рекр\./g,'').replace(',','.');
  const match=normalized.match(/-?\d+(?:\.\d+)?/);
  return match?Number(match[0]):null;
}

function sortBy(table,index,cell){
  const body=table.tBodies[0];if(!body)return;
  const direction=cell.dataset.sortDir==='asc'?'desc':'asc';
  [...table.tHead.rows[0].cells].forEach(other=>{delete other.dataset.sortDir;other.classList.remove('sort-asc','sort-desc');});
  cell.dataset.sortDir=direction;
  cell.classList.add(direction==='asc'?'sort-asc':'sort-desc');
  const rows=[...body.rows];
  rows.sort((left,right)=>{
    const a=cellNumber(left.cells[index]),b=cellNumber(right.cells[index]);
    if(a!==null&&b!==null)return direction==='asc'?a-b:b-a;
    const at=String(left.cells[index]?.innerText||'').trim(),bt=String(right.cells[index]?.innerText||'').trim();
    return direction==='asc'?at.localeCompare(bt,'ru'):bt.localeCompare(at,'ru');
  });
  rows.forEach(row=>body.append(row));
}

export function filterRows(table,predicate){
  if(!table?.tBodies?.[0])return;
  [...table.tBodies[0].rows].forEach(row=>{row.hidden=!predicate(row);});
}
