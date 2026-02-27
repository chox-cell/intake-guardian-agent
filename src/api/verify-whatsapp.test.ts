import { describe, it, before, after } from 'node:test';
import assert from 'node:assert';
import { verifyWhatsAppMessageAge } from './verify-whatsapp.js';

describe('verifyWhatsAppMessageAge', () => {
  const originalEnv = process.env;
  const originalDateNow = Date.now;

  before(() => {
    // Freeze time to a known value: 2023-01-01T12:00:00Z (1672574400000 ms)
    const MOCKED_NOW = 1672574400000;
    Date.now = () => MOCKED_NOW;
    process.env = { ...originalEnv }; // Clone env to avoid polluting global state
  });

  after(() => {
    // Restore original Date.now and process.env
    Date.now = originalDateNow;
    process.env = originalEnv;
  });

  it('should return ok: true for a fresh message (within 600s default)', () => {
    // 1672574400 seconds = MOCKED_NOW / 1000
    // Message sent 100 seconds ago
    const messageTs = 1672574400 - 100;
    const reqBody = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: String(messageTs)
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(reqBody);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should return ok: false for an old message (> 600s default)', () => {
    // Message sent 601 seconds ago
    const messageTs = 1672574400 - 601;
    const reqBody = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: String(messageTs)
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(reqBody);
    assert.deepStrictEqual(result, { ok: false, error: 'message_too_old' });
  });

  it('should return ok: true for a message exactly at the limit (600s default)', () => {
    // Message sent exactly 600 seconds ago
    const messageTs = 1672574400 - 600;
    const reqBody = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: String(messageTs)
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(reqBody);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should return ok: true if timestamp is missing', () => {
    const reqBody = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              // no timestamp
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(reqBody);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should return error if timestamp is invalid (non-numeric)', () => {
    const reqBody = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: "invalid-date"
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(reqBody);
    assert.deepStrictEqual(result, { ok: false, error: 'invalid_message_timestamp' });
  });

  it('should handle malformed body gracefully (return ok: true)', () => {
    // Empty body
    let result = verifyWhatsAppMessageAge({});
    assert.deepStrictEqual(result, { ok: true });

    // Null body
    result = verifyWhatsAppMessageAge(null);
    assert.deepStrictEqual(result, { ok: true });

    // Deeply nested missing property
    result = verifyWhatsAppMessageAge({ entry: [{ changes: [] }] });
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should respect WA_MAX_AGE_SECONDS environment variable', () => {
    process.env.WA_MAX_AGE_SECONDS = '300'; // Set max age to 300 seconds

    // Message sent 400 seconds ago (should fail with new limit)
    const messageTs = 1672574400 - 400;
    const reqBody = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: String(messageTs)
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(reqBody);
    assert.deepStrictEqual(result, { ok: false, error: 'message_too_old' });

    // Reset env for subsequent tests if any (though 'after' hook handles global reset)
    delete process.env.WA_MAX_AGE_SECONDS;
  });
});
