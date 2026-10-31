const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// A small, explicit document format keeps pasted HTML and browser markup out of storage.
export function readWallDocument(editor) {
  const blocks = [];
  const inline = (node, marks, out) => {
    if (node.nodeType === Node.TEXT_NODE) { if (node.nodeValue) out.push({text:node.nodeValue, ...marks}); return; }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    if (node.tagName === 'BR') { out.push({text:'\n', ...marks}); return; }
    const style = node.style || {};
    const next = {bold:marks.bold || /^(B|STRONG)$/.test(node.tagName) || /^(bold|[6-9]00)$/.test(style.fontWeight), italic:marks.italic || /^(I|EM)$/.test(node.tagName) || style.fontStyle === 'italic', underline:marks.underline || node.tagName === 'U' || style.textDecorationLine?.includes('underline') || style.textDecoration?.includes('underline')};
    node.childNodes.forEach(child => inline(child,next,out));
  };
  const add = (node,type) => { const spans=[]; node.childNodes.forEach(child=>inline(child,{bold:false,italic:false,underline:false},spans)); if(spans.length===1 && spans[0].text==='\n') spans.length=0; blocks.push({type,spans}); };
  const visit = parent => {
    let loose=[];
    const flush=()=>{if(loose.length){const holder=document.createElement('div');loose.forEach(n=>holder.appendChild(n.cloneNode(true)));add(holder,'p');loose=[];}};
    parent.childNodes.forEach(node=>{
      if(node.nodeType===Node.ELEMENT_NODE && /^(UL|OL)$/.test(node.tagName)){
        flush(); node.querySelectorAll(':scope > li').forEach(li=>add(li,node.tagName==='UL'?'ul':'ol'));
      } else if(node.nodeType===Node.ELEMENT_NODE && /^(P|DIV|H2|H3)$/.test(node.tagName)){
        flush();
        if(node.querySelector(':scope > ul, :scope > ol, :scope > div, :scope > p')) visit(node);
        else add(node,node.tagName.toLowerCase()==='h2'?'h2':node.tagName.toLowerCase()==='h3'?'h3':'p');
      } else loose.push(node);
    });
    flush();
  };
  visit(editor); return blocks;
}
export const wallPlainText = blocks => blocks.map(block=>block.spans.map(span=>span.text).join('')).join('\n').trim();
export function renderWallDocument(blocks) {
  if(!Array.isArray(blocks)) return '';
  let result='',list='';
  for(const block of blocks){
    const type=['p','h2','h3','ul','ol'].includes(block.type)?block.type:'p';
    if(type!==list){if(list)result+=`</${list}>`;list=(type==='ul'||type==='ol')?type:'';if(list)result+=`<${list}>`;}
    const tag=list?'li':type;
    const contents=(Array.isArray(block.spans)?block.spans:[]).map(span=>{let text=esc(span.text).replace(/\n/g,'<br>');if(span.bold)text=`<strong>${text}</strong>`;if(span.italic)text=`<em>${text}</em>`;if(span.underline)text=`<u>${text}</u>`;return text;}).join('');
    result+=`<${tag}>${contents || '<br>'}</${tag}>`;
  }
  if(list)result+=`</${list}>`;return result;
}
export function setupWallEditor(form) {
  const editor=form.querySelector('[data-wall-editor]'), count=form.querySelector('[data-count]');
  const update=()=>{count.textContent=`${Array.from(wallPlainText(readWallDocument(editor))).length.toLocaleString('ru-RU')} / 30 000`;};
  editor.addEventListener('input',update);
  form.querySelectorAll('[data-command]').forEach(button=>{
    button.addEventListener('mousedown',event=>event.preventDefault());
    button.addEventListener('click',()=>{editor.focus();document.execCommand(button.dataset.command,false,button.dataset.value || null);update();});
  });
  editor.addEventListener('paste',event=>{event.preventDefault();document.execCommand('insertText',false,event.clipboardData.getData('text/plain'));});
  return {editor, document:()=>readWallDocument(editor)};
}
