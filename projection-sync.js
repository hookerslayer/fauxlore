/** Keep projections aligned with the map snapshot used to render them. */
export async function loadConsistentProjection(request,{getRevision,refreshMap,maxAttempts=3,wait=ms=>new Promise(resolve=>setTimeout(resolve,ms))}){
  let lastError;
  for(let attempt=0;attempt<maxAttempts;attempt++){
    try{
      const result=await request();
      const current=getRevision();
      if(String(result.data_revision)===String(current.data_revision)&&String(result.live_revision)===String(current.live_revision))return result;
      lastError=new Error('Не удалось согласовать данные с картой. Повторите загрузку.');
      if(attempt+1<maxAttempts)await refreshMap();
    }catch(error){
      const networkError=error instanceof TypeError&&/fetch|network/i.test(error.message);
      if(!error.retryable&&!networkError)throw error;
      lastError=error;
    }
    if(attempt+1<maxAttempts)await wait(250*(attempt+1));
  }
  throw lastError;
}

/** Ignore an older map response that arrives after a newer one. */
export function isOlderMapRevision(incoming,current){
  try{
    return BigInt(incoming.data_revision)<BigInt(current.data_revision)||BigInt(incoming.live_revision)<BigInt(current.live_revision);
  }catch{return false;}
}

/** Retry while the original UI remains mounted; defer if the caller reports unsaved edits. */
export function scheduleAutomaticRetry({isActive,attempt,delay=5000,schedule=setTimeout}){
  const run=()=>{
    if(!isActive())return;
    if(attempt()===false)schedule(run,delay);
  };
  schedule(run,delay);
}
