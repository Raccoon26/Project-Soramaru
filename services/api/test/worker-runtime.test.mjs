import process from 'node:process';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fileURLToPath, URL } from 'node:url';
import { createServer } from 'vite';

test('local Workers runtime serves the liveness endpoint', { timeout: 30000 }, async () => {
  process.env.SORAMARU_RUNTIME = 'test';
  const server = await createServer({
    root: fileURLToPath(new URL('../', import.meta.url)),
    server: { host: '127.0.0.1', port: 0 },
    clearScreen: false,
  });

  try {
    await server.listen();
    const address = server.httpServer?.address();
    assert.ok(address && typeof address === 'object');
    const response = await globalThis.fetch(
      'http://127.0.0.1:' + address.port + '/v1/health',
      { signal: globalThis.AbortSignal.timeout(10000) },
    );

    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: 'ok' });
    const ready=await globalThis.fetch('http://127.0.0.1:' + address.port + '/v1/ready',
      { signal: globalThis.AbortSignal.timeout(10000) });
    assert.equal(ready.status,503);
    assert.deepEqual(await ready.json(),{error:{code:'unavailable'}});
  } finally {
    await server.close();
  }
});
