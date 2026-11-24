import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker from '../services/api/src/index.ts';

test('GET /v1/health returns the public liveness contract', async () => {
  const response = worker.fetch(new globalThis.Request('http://localhost/v1/health'));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  assert.match(response.headers.get('Content-Type'), /^application\/json/);
  assert.deepEqual(await response.json(), { status: 'ok' });
});

test('unsupported methods and unknown paths return the API error contract', async () => {
  const method = worker.fetch(new globalThis.Request('http://localhost/v1/health', { method: 'POST' }));
  assert.equal(method.status, 405);
  assert.equal(method.headers.get('Allow'), 'GET');
  assert.deepEqual(await method.json(), { error: { code: 'method_not_allowed' } });

  const path = worker.fetch(new globalThis.Request('http://localhost/private'));
  assert.equal(path.status, 404);
  assert.deepEqual(await path.json(), { error: { code: 'not_found' } });
});
