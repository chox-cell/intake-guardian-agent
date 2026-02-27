import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert";
import { Webhook } from "svix";
import { verifyResendWebhook } from "./verify-resend.js";
import type { RawBodyRequest } from "./raw-body.js";

describe("verifyResendWebhook", () => {
  const originalEnv = { ...process.env };
  const validSecret = "whsec_" + Buffer.from("a".repeat(32)).toString("base64");

  // Helper to create a mock request
  function createMockRequest(headers: Record<string, string>, body: string | undefined): RawBodyRequest {
    return {
      header: (name: string) => headers[name.toLowerCase()] || "",
      rawBody: body !== undefined ? Buffer.from(body) : undefined,
    } as unknown as RawBodyRequest;
  }

  // Helper to generate valid svix headers
  function generateSvixHeaders(secret: string, payload: string, timestamp?: number) {
    const wh = new Webhook(secret);
    const ts = timestamp ?? Math.floor(Date.now() / 1000);
    const msgId = "msg_" + Math.random().toString(36).substring(7);

    // sign method returns "v1,signature"
    const signature = (wh as any).sign(msgId, new Date(ts * 1000), payload);
    const sigHash = signature.split(",")[1];

    return {
      "svix-id": msgId,
      "svix-timestamp": String(ts),
      "svix-signature": signature // The verify function seems to expect the full signature including version prefix if checking against split(' ')
    };
  }

  beforeEach(() => {
    process.env.ENFORCE_RESEND_SIG = "false";
    process.env.RESEND_WEBHOOK_SECRET = "";
    process.env.RESEND_MAX_SKEW_SECONDS = "300";
  });

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  test("should allow pass-through when not enforced and no secret", () => {
    process.env.ENFORCE_RESEND_SIG = "false";
    delete process.env.RESEND_WEBHOOK_SECRET;

    const req = createMockRequest({}, "some body");
    const result = verifyResendWebhook(req);

    assert.deepStrictEqual(result, { ok: true });
  });

  test("should allow pass-through when not enforced, even if verification fails", () => {
    process.env.ENFORCE_RESEND_SIG = "false";
    process.env.RESEND_WEBHOOK_SECRET = validSecret;

    const req = createMockRequest({
        "svix-id": "1",
        "svix-timestamp": "1",
        "svix-signature": "invalid"
    }, "some body");

    const result = verifyResendWebhook(req);
    assert.deepStrictEqual(result, { ok: true });
  });

  test("should return error when enforced and missing headers", () => {
    process.env.ENFORCE_RESEND_SIG = "true";
    process.env.RESEND_WEBHOOK_SECRET = validSecret;

    const req = createMockRequest({}, "some body");
    const result = verifyResendWebhook(req);

    assert.deepStrictEqual(result, { ok: false, error: "missing_svix_headers_or_secret_or_raw_body" });
  });

  test("should return error when enforced and missing body", () => {
    process.env.ENFORCE_RESEND_SIG = "true";
    process.env.RESEND_WEBHOOK_SECRET = validSecret;

    const headers = generateSvixHeaders(validSecret, "body");
    const req = createMockRequest(headers, undefined);

    const result = verifyResendWebhook(req);
    assert.deepStrictEqual(result, { ok: false, error: "missing_svix_headers_or_secret_or_raw_body" });
  });

  test("should return error when enforced and missing secret", () => {
    process.env.ENFORCE_RESEND_SIG = "true";
    delete process.env.RESEND_WEBHOOK_SECRET;

    const req = createMockRequest({}, "some body");
    const result = verifyResendWebhook(req);

    assert.deepStrictEqual(result, { ok: false, error: "missing_svix_headers_or_secret_or_raw_body" });
  });

  test("should return error when enforced and invalid timestamp", () => {
    process.env.ENFORCE_RESEND_SIG = "true";
    process.env.RESEND_WEBHOOK_SECRET = validSecret;

    const headers = generateSvixHeaders(validSecret, "body");
    headers["svix-timestamp"] = "not-a-number";

    const req = createMockRequest(headers, "body");
    const result = verifyResendWebhook(req);

    assert.deepStrictEqual(result, { ok: false, error: "invalid_svix_timestamp" });
  });

  test("should return error when enforced and timestamp skew", () => {
    process.env.ENFORCE_RESEND_SIG = "true";
    process.env.RESEND_WEBHOOK_SECRET = validSecret;
    process.env.RESEND_MAX_SKEW_SECONDS = "300";

    const now = Math.floor(Date.now() / 1000);
    const oldTimestamp = now - 400; // 400 seconds ago

    const headers = generateSvixHeaders(validSecret, "body", oldTimestamp);

    const req = createMockRequest(headers, "body");
    const result = verifyResendWebhook(req);

    assert.deepStrictEqual(result, { ok: false, error: "svix_timestamp_skew" });
  });

  test("should return error when enforced and invalid signature", () => {
    process.env.ENFORCE_RESEND_SIG = "true";
    process.env.RESEND_WEBHOOK_SECRET = validSecret;

    const headers = generateSvixHeaders(validSecret, "body");
    headers["svix-signature"] = "v1,badsignature";

    const req = createMockRequest(headers, "body");
    const result = verifyResendWebhook(req);

    assert.deepStrictEqual(result, { ok: false, error: "invalid_resend_signature" });
  });

  test("should return OK when enforced and valid signature", () => {
    process.env.ENFORCE_RESEND_SIG = "true";
    process.env.RESEND_WEBHOOK_SECRET = validSecret;

    const payload = '{"type":"test"}';
    const headers = generateSvixHeaders(validSecret, payload);

    const req = createMockRequest(headers, payload);
    const result = verifyResendWebhook(req);

    assert.deepStrictEqual(result, { ok: true });
  });
});
