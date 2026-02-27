import { describe, it } from 'node:test';
import assert from 'node:assert';
import { classifyPriority } from './it-support.v1.js';

describe('classifyPriority', () => {
  it('should return critical for server_outage category', () => {
    const priority = classifyPriority('server seems fine', 'server_outage');
    assert.strictEqual(priority, 'critical');
  });

  it('should return high when normalized text contains "down"', () => {
    const priority = classifyPriority('system is down', 'unknown');
    assert.strictEqual(priority, 'high');
  });

  it('should return high when normalized text contains "urgent"', () => {
    const priority = classifyPriority('this is urgent request', 'unknown');
    assert.strictEqual(priority, 'high');
  });

  it('should return high when normalized text contains "asap"', () => {
    const priority = classifyPriority('need help asap', 'unknown');
    assert.strictEqual(priority, 'high');
  });

  it('should return high for network_wifi category', () => {
    const priority = classifyPriority('wifi slow', 'network_wifi');
    assert.strictEqual(priority, 'high');
  });

  it('should return normal for auth_password category', () => {
    const priority = classifyPriority('forgot password', 'auth_password');
    assert.strictEqual(priority, 'normal');
  });

  it('should return low for unknown category with no keywords', () => {
    const priority = classifyPriority('just a question', 'unknown');
    assert.strictEqual(priority, 'low');
  });

  it('should prioritize server_outage over keywords', () => {
    // server_outage returns critical immediately
    // keywords usually return high
    // so critical > high
    const priority = classifyPriority('system is down and urgent', 'server_outage');
    assert.strictEqual(priority, 'critical');
  });

  it('should prioritize keywords over auth_password', () => {
    // keywords return high
    // auth_password returns normal
    // keyword check is before auth_password check
    const priority = classifyPriority('urgent password reset', 'auth_password');
    assert.strictEqual(priority, 'high');
  });
});
