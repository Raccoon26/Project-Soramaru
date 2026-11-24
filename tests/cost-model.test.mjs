
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { model,scenarios,storage } from '../tools/model-cost.mjs';

test('model covers all sizes, traffic profiles and growing retention without papering over overages',()=>{
  for (const size of [100,500,1000,5000]) {
    for (const scenario of Object.keys(scenarios)) {
      const day=model(size,scenario);
      assert.ok(day.peakConcurrent<=day.dau&&day.dau<=size);
      assert.ok(day.d1Writes>=day.dau&&day.r2B>day.r2A);
    }
    for (const months of [6,12,24,36]) {
      assert.ok(storage(size,months).peakGB>storage(size,months-1).peakGB);
    }
  }
  assert.ok(model(100,'ordinary').ratio<.70);
  assert.ok(model(5000,'abuse').ratio>1);
  assert.ok(model(5000,'ordinary',36).usd>0);
});
