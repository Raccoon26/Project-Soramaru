
import assert from 'node:assert/strict';
import { URL,fileURLToPath } from 'node:url';
import { createServer } from 'vite';

const runtime = await createServer({
  root:fileURLToPath(new URL('../services/api',import.meta.url)),
  server:{host:'127.0.0.1',port:0},clearScreen:false,
});
try {
  await runtime.listen();
  const address=runtime.httpServer?.address();
  assert.ok(address && typeof address==='object');
  const origin='http://127.0.0.1:' + address.port;
  const get=(path,headers={})=>globalThis.fetch(origin+path,{headers,signal:globalThis.AbortSignal.timeout(10_000)});
  const ready=await get('/v1/ready');
  assert.equal(ready.status,200);
  assert.deepEqual(await ready.json(),{status:'ready'});
  const unauthenticated=await get('/v1/me/session',{'Authorization':'Bearer fixture-no-access','X-Role':'administrator'});
  assert.equal(unauthenticated.status,401);
  assert.deepEqual(await unauthenticated.json(),{error:{code:'authentication_required'}});
  globalThis.console.log('Local workerd reached the migrated D1 and rejected synthetic authentication.');
} finally {
  await runtime.close();
}
