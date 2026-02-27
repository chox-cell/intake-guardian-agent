import { describe, it, before, after, mock } from 'node:test';
import assert from 'node:assert';
import crypto from 'node:crypto';
import { verifyWhatsAppSignature, verifyWhatsAppMessageAge } from './verify-whatsapp.js';

// Mock Request interface
interface MockRequest {
  headers: Record<string, string>;
  rawBody?: Buffer;
  header(name: string): string | undefined;
}

function createMockRequest(headers: Record<string, string> = {}, rawBodyStr: string = ''): MockRequest {
  const normalizedHeaders: Record<string, string> = {};
  for (const key in headers) {
    normalizedHeaders[key.toLowerCase()] = headers[key];
  }

  return {
    headers: normalizedHeaders,
    rawBody: Buffer.from(rawBodyStr),
    header(name: string) {
      return this.headers[name.toLowerCase()];
    }
  };
}

describe('verifyWhatsAppSignature', () => {
  let originalEnv: NodeJS.ProcessEnv;

  before(() => {
    originalEnv = { ...process.env };
  });

  after(() => {
    process.env = originalEnv;
  });

  it('should pass when enforcement is disabled (default)', () => {
    delete process.env.ENFORCE_WA_SIG;
    process.env.WA_APP_SECRET = 'secret';

    const req = createMockRequest({}, 'payload');
    const result = verifyWhatsAppSignature(req as any);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should pass when enforcement is explicitly false', () => {
    process.env.ENFORCE_WA_SIG = 'false';
    process.env.WA_APP_SECRET = 'secret';

    const req = createMockRequest({}, 'payload');
    const result = verifyWhatsAppSignature(req as any);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should fail when enforcement is enabled and signature is missing', () => {
    process.env.ENFORCE_WA_SIG = 'true';
    process.env.WA_APP_SECRET = 'secret';

    const req = createMockRequest({}, 'payload');
    const result = verifyWhatsAppSignature(req as any);
    assert.deepStrictEqual(result, { ok: false, error: 'missing_signature_or_secret_or_raw_body' });
  });

  it('should fail when enforcement is enabled and secret is missing', () => {
    process.env.ENFORCE_WA_SIG = 'true';
    delete process.env.WA_APP_SECRET;

    const req = createMockRequest({ 'x-hub-signature-256': 'sha256=valid' }, 'payload');
    const result = verifyWhatsAppSignature(req as any);
    assert.deepStrictEqual(result, { ok: false, error: 'missing_signature_or_secret_or_raw_body' });
  });

  it('should fail when enforcement is enabled and raw body is empty', () => {
    process.env.ENFORCE_WA_SIG = 'true';
    process.env.WA_APP_SECRET = 'secret';

    const req = createMockRequest({ 'x-hub-signature-256': 'sha256=valid' }, '');
    const result = verifyWhatsAppSignature(req as any);
    assert.deepStrictEqual(result, { ok: false, error: 'missing_signature_or_secret_or_raw_body' });
  });

  it('should pass when enforcement is enabled and signature is valid', () => {
    process.env.ENFORCE_WA_SIG = 'true';
    const secret = 'my_secret_key';
    process.env.WA_APP_SECRET = secret;
    const payload = '{"object":"whatsapp_business_account"}';

    const expectedSig = 'sha256=' + crypto.createHmac('sha256', secret).update(payload).digest('hex');

    const req = createMockRequest({ 'x-hub-signature-256': expectedSig }, payload);
    const result = verifyWhatsAppSignature(req as any);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should fail when enforcement is enabled and signature is invalid', () => {
    process.env.ENFORCE_WA_SIG = 'true';
    process.env.WA_APP_SECRET = 'secret';
    const payload = 'payload';

    const req = createMockRequest({ 'x-hub-signature-256': 'sha256=invalid_signature' }, payload);
    const result = verifyWhatsAppSignature(req as any);
    assert.deepStrictEqual(result, { ok: false, error: 'invalid_whatsapp_signature' });
  });

  it('should fail when enforcement is enabled and signature length does not match', () => {
     process.env.ENFORCE_WA_SIG = 'true';
     process.env.WA_APP_SECRET = 'secret';
     const payload = 'payload';

     // Signature too short
     const req = createMockRequest({ 'x-hub-signature-256': 'sha256=short' }, payload);
     const result = verifyWhatsAppSignature(req as any);
     assert.deepStrictEqual(result, { ok: false, error: 'invalid_whatsapp_signature' });
   });
});

describe('verifyWhatsAppMessageAge', () => {
  let originalEnv: NodeJS.ProcessEnv;

  before(() => {
    originalEnv = { ...process.env };
  });

  after(() => {
    process.env = originalEnv;
    mock.reset();
  });

  it('should pass for recent message', () => {
    const now = 1600000000;
    mock.method(Date, 'now', () => now * 1000);

    const body = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: String(now - 100) // 100 seconds ago
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(body);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should pass for message with default max age (600s) boundary', () => {
    const now = 1600000000;
    mock.method(Date, 'now', () => now * 1000);

    const body = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: String(now - 600)
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(body);
    assert.deepStrictEqual(result, { ok: true });
  });

  it('should fail for old message (> 600s)', () => {
    const now = 1600000000;
    mock.method(Date, 'now', () => now * 1000);

    const body = {
      entry: [{
        changes: [{
          value: {
            messages: [{
              timestamp: String(now - 601)
            }]
          }
        }]
      }]
    };

    const result = verifyWhatsAppMessageAge(body);
    assert.deepStrictEqual(result, { ok: false, error: 'message_too_old' });
  });

  it('should pass when timestamp is missing', () => {
    const body = {
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

      const result = verifyWhatsAppMessageAge(body);
      assert.deepStrictEqual(result, { ok: true });
  });

  it('should fail when timestamp is invalid', () => {
    const body = {
        entry: [{
          changes: [{
            value: {
              messages: [{
                timestamp: "not_a_number"
              }]
            }
          }]
        }]
      };

      const result = verifyWhatsAppMessageAge(body);
      assert.deepStrictEqual(result, { ok: false, error: 'invalid_message_timestamp' });
  });

  it('should respect custom WA_MAX_AGE_SECONDS', () => {
      process.env.WA_MAX_AGE_SECONDS = '300';
      const now = 1600000000;
      mock.method(Date, 'now', () => now * 1000);

      const body = {
        entry: [{
          changes: [{
            value: {
              messages: [{
                timestamp: String(now - 301)
              }]
            }
          }]
        }]
      };

      const result = verifyWhatsAppMessageAge(body);
      assert.deepStrictEqual(result, { ok: false, error: 'message_too_old' });
  });

  it('should return ok: true on unexpected error structure (try/catch block)', () => {
     // Passing null/undefined might trigger the optional chaining ? safe return, or if we force a throw
     // The code is:
     // try { const msg = reqBody?.entry...; ... } catch { return { ok: true }; }
     // So if we pass something that causes an error inside try other than the checks, it returns ok: true.
     // However, the optional chaining makes it hard to crash.
     // But let's verify basic safety with empty body
     const result = verifyWhatsAppMessageAge({});
     assert.deepStrictEqual(result, { ok: true });
  });
});
