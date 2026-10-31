import assert from 'node:assert/strict';
import {loadConsistentProjection,isOlderMapRevision,scheduleAutomaticRetry} from '../projection-sync.js';
const rev=(data,live)=>({data_revision:data,live_revision:live});
const immediate=async()=>{};
{
 let current=rev(1,2),requests=0,refreshes=0;
 const result=await loadConsistentProjection(async()=>{requests++;return rev(2,3)},{getRevision:()=>current,refreshMap:async()=>{refreshes++;current=rev(2,3)},wait:immediate});
 assert.deepEqual(result,rev(2,3));assert.equal(requests,2);assert.equal(refreshes,1);
}
{
 let current=rev(1,1),requests=0,refreshes=0;
 const answers=[rev(1,1),rev(2,2)];
 const result=await loadConsistentProjection(async()=>{const answer=answers[requests++];if(requests===1)current=rev(2,2);return answer},{getRevision:()=>current,refreshMap:async()=>{refreshes++},wait:immediate});
 assert.deepEqual(result,rev(2,2));assert.equal(refreshes,1);
}
{
 let requests=0,refreshes=0;
 await assert.rejects(loadConsistentProjection(async()=>{requests++;return rev(2,3)},{getRevision:()=>rev(1,1),refreshMap:async()=>{refreshes++},maxAttempts:3,wait:immediate}),/Не удалось согласовать/);
 assert.equal(requests,3);assert.equal(refreshes,2);
}
{
 const error=new Error('Сеть недоступна');
 await assert.rejects(loadConsistentProjection(async()=>{throw error},{getRevision:()=>rev(1,1),refreshMap:async()=>{throw new Error('unexpected')}}),e=>e===error);
}
{
 let requests=0,waits=[];const temporary=Object.assign(new Error('Временная ошибка'),{retryable:true});
 const result=await loadConsistentProjection(async()=>{if(++requests<3)throw temporary;return rev(5,5)},{getRevision:()=>rev(5,5),refreshMap:async()=>{},wait:async ms=>waits.push(ms)});
 assert.deepEqual(result,rev(5,5));assert.equal(requests,3);assert.deepEqual(waits,[250,500]);
}
{
 let requests=0;const forbidden=Object.assign(new Error('Нет доступа'),{status:403,retryable:false});
 await assert.rejects(loadConsistentProjection(async()=>{requests++;throw forbidden},{getRevision:()=>rev(1,1),refreshMap:async()=>{},wait:immediate}),e=>e===forbidden);assert.equal(requests,1);
}
{
 let requests=0,refreshes=0;const temporary=Object.assign(new Error('Сеть'),{retryable:true});let current=rev(1,1);
 const result=await loadConsistentProjection(async()=>{requests++;return rev(2,2)},{getRevision:()=>current,refreshMap:async()=>{if(++refreshes===1)throw temporary;current=rev(2,2)},wait:immediate});
 assert.deepEqual(result,rev(2,2));assert.equal(requests,3);assert.equal(refreshes,2);
}
{
 let requests=0;const result=await loadConsistentProjection(async()=>{if(++requests===1)throw new TypeError('Failed to fetch');return rev(1,1)},{getRevision:()=>rev(1,1),refreshMap:async()=>{},wait:immediate});
 assert.deepEqual(result,rev(1,1));assert.equal(requests,2);
}
{
 let requests=0;const badData=new TypeError('Invalid data');
 await assert.rejects(loadConsistentProjection(async()=>{requests++;throw badData},{getRevision:()=>rev(1,1),refreshMap:async()=>{},wait:immediate}),e=>e===badData);assert.equal(requests,1);
}
{
 const timers=[];let mounted=true,dirty=true,attempts=0;
 scheduleAutomaticRetry({isActive:()=>mounted,attempt:()=>{attempts++;if(dirty)return false;},schedule:fn=>timers.push(fn)});
 timers.shift()();assert.equal(attempts,1);assert.equal(timers.length,1);
 dirty=false;timers.shift()();assert.equal(attempts,2);assert.equal(timers.length,0);
 scheduleAutomaticRetry({isActive:()=>mounted,attempt:()=>{attempts++},schedule:fn=>timers.push(fn)});
 mounted=false;timers.shift()();assert.equal(attempts,2);
}
assert.equal(isOlderMapRevision(rev(3,4),rev(2,3)),false);
assert.equal(isOlderMapRevision(rev(1,4),rev(2,3)),true);
assert.equal(isOlderMapRevision(rev(3,2),rev(2,3)),true);
console.log('PASS: projection revisions, races, bounded retries and failures');
