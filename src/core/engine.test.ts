import { describe, it, mock } from "node:test";
import assert from "node:assert";
import { buildWorkItem } from "./engine.js";
import { InboundEvent } from "../types/contracts.js";
import * as support from "../presets/it-support.v1.js";

describe("buildWorkItem", () => {
  it("should create a critical work item for server outage", (t) => {
    // Mock Date to ensure deterministic timestamps
    const mockDate = new Date("2023-10-26T12:00:00Z");
    t.mock.timers.enable({ now: mockDate });

    const event: InboundEvent = {
      tenantId: "tenant-1",
      source: "email",
      sender: "user@example.com",
      subject: "Server Outage",
      body: "The production server is experiencing an outage!",
      receivedAt: mockDate.toISOString(),
    };

    const result = buildWorkItem(event, support.presetId);

    assert.strictEqual(result.tenantId, "tenant-1");
    // "outage" triggers server_outage, which triggers critical priority
    assert.strictEqual(result.category, "server_outage");
    assert.strictEqual(result.priority, "critical");
    assert.strictEqual(result.status, "triage");
    assert.strictEqual(result.slaSeconds, 3600);
    assert.strictEqual(result.createdAt, mockDate.toISOString());
    assert.strictEqual(result.updatedAt, mockDate.toISOString());

    // Check dueAt calculation (1 hour later)
    const expectedDueAt = new Date(mockDate.getTime() + 3600 * 1000).toISOString();
    assert.strictEqual(result.dueAt, expectedDueAt);

    // Check ID and fingerprint existence
    assert.ok(result.id, "ID should be generated");
    assert.ok(result.fingerprint, "Fingerprint should be generated");
  });

  it("should create a normal work item for password reset", (t) => {
    const mockDate = new Date("2023-10-26T12:00:00Z");
    t.mock.timers.enable({ now: mockDate });

    const event: InboundEvent = {
      tenantId: "tenant-1",
      source: "email",
      sender: "user@example.com",
      subject: "Password Reset",
      body: "I forgot my password, please reset.",
      receivedAt: mockDate.toISOString(),
    };

    const result = buildWorkItem(event, support.presetId);

    assert.strictEqual(result.priority, "normal");
    assert.strictEqual(result.status, "new"); // Normal priority -> new status
    assert.strictEqual(result.category, "auth_password");
    assert.strictEqual(result.slaSeconds, 86400); // 24 hours
  });

  it("should throw error for unknown presetId", () => {
    const event: InboundEvent = {
        tenantId: "tenant-1",
        source: "email",
        sender: "user@example.com",
        subject: "Test",
        body: "Test body",
        receivedAt: new Date().toISOString(),
    };

    assert.throws(() => {
        buildWorkItem(event, "unknown_preset");
    }, /Unknown presetId: unknown_preset/);
  });
});
