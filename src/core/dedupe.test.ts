import { test, describe } from "node:test";
import assert from "node:assert";
import crypto from "crypto";
import { fingerprintOf } from "./dedupe";

describe("fingerprintOf", () => {
  test("should be deterministic (same input produces same hash)", () => {
    const input = {
      tenantId: "tenant1",
      sender: "sender1",
      normalizedBody: "body1",
      presetId: "preset1",
    };
    const hash1 = fingerprintOf(input);
    const hash2 = fingerprintOf(input);
    assert.strictEqual(hash1, hash2);
  });

  test("should be sensitive to changes (different input produces different hash)", () => {
    const input1 = {
      tenantId: "tenant1",
      sender: "sender1",
      normalizedBody: "body1",
      presetId: "preset1",
    };
    const input2 = { ...input1, sender: "sender2" };
    const hash1 = fingerprintOf(input1);
    const hash2 = fingerprintOf(input2);
    assert.notStrictEqual(hash1, hash2);
  });

  test("should match known vector", () => {
    const input = {
      tenantId: "tenant_demo",
      sender: "test@example.com",
      normalizedBody: "test body content",
      presetId: "default",
    };
    // Manually calculate expected hash
    // raw = "tenant_demo|test@example.com|default|test body content"
    // echo -n "tenant_demo|test@example.com|default|test body content" | sha256sum
    const raw = `${input.tenantId}|${input.sender}|${input.presetId}|${input.normalizedBody}`;
    const expected = crypto.createHash("sha256").update(raw).digest("hex");

    const actual = fingerprintOf(input);
    assert.strictEqual(actual, expected);
  });

  test("should handle empty strings", () => {
    const input = {
      tenantId: "",
      sender: "",
      normalizedBody: "",
      presetId: "",
    };
    const hash = fingerprintOf(input);
    assert.ok(hash);
    assert.strictEqual(hash.length, 64); // SHA-256 hex string length
  });
});
