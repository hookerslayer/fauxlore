import assert from 'node:assert/strict';

globalThis.window = {FAUXLORE_CONFIG: {backend: 'vps-postgrest'}};
let closed = 0, keys = [];
globalThis.indexedDB = {open() {
  const opening = {result: {
    close() { closed++; },
    transaction() { return {objectStore() { return {
      get(key) { keys.push(key); throw new Error('cache unavailable'); },
      put(_value, key) { keys.push(key); throw new Error('cache unavailable'); },
    }; }}; },
  }};
  queueMicrotask(() => opening.onsuccess());
  return opening;
}};
globalThis.fetch = async url => url === 'map-data/province-adjacency.json'
  ? Response.json({}) : Response.json({provinces: [], region: []});
const {loadSupabaseInitialMap} = await import('../supabase-api.js');
const result = await Promise.race([loadSupabaseInitialMap(), new Promise((_, reject) =>
  setTimeout(() => reject(new Error('Map load hung when cache failed')), 1000))]);
assert.deepEqual(result.provinces, []);
assert.ok(closed >= 1);
assert.ok(keys.every(key => key === 'vps-postgrest'));
console.log('Map cache failure: fallback to server passed');
