import { test } from 'node:test';
import assert from 'node:assert';
import { buildWorkItem } from './engine.js';
import * as it from '../presets/it-support.v1.js';
import { InboundEvent } from '../types/contracts.js';

test('buildWorkItem throws for invalid presetId', () => {
  const ev: InboundEvent = {
    tenantId: 'tenant1',
    source: 'email',
    sender: 'user@example.com',
    body: 'help me',
    receivedAt: new Date().toISOString()
  };

  assert.throws(() => {
    buildWorkItem(ev, 'invalid-preset');
  }, /Unknown presetId: invalid-preset/);
});

test('buildWorkItem works for valid presetId', () => {
    const ev: InboundEvent = {
        tenantId: 'tenant1',
        source: 'email',
        sender: 'user@example.com',
        body: 'help me',
        receivedAt: new Date().toISOString()
    };

    const workItem = buildWorkItem(ev, it.presetId);
    assert.strictEqual(workItem.presetId, it.presetId);
});
