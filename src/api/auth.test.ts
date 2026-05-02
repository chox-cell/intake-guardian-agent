import test from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import path from "node:path";
import express from "express";
import crypto from "node:crypto";
import { authRouter } from "./auth.js";

function makeMockRequest(method: string, url: string, body?: any, query?: any) {
  const req: any = {
    method,
    url,
    body,
    query,
    headers: {},
    ip: "127.0.0.1",
  };
  return req;
}

function makeMockResponse(onEnd: (status: number, data: any, headers: any) => void) {
  let statusCode = 200;
  const headers: any = {};
  const res: any = {
    status: (code: number) => {
      statusCode = code;
      return res;
    },
    setHeader: (k: string, v: string) => {
      headers[k] = v;
      return res;
    },
    json: (obj: any) => {
      onEnd(statusCode, obj, headers);
      return res;
    },
    send: (str: string) => {
      onEnd(statusCode, str, headers);
      return res;
    },
    redirect: (code: number, url: string) => {
      statusCode = code;
      headers["location"] = url;
      onEnd(statusCode, { location: url }, headers);
      return res;
    },
  };
  return res;
}

test("authRouter token generation and verification using hash", async (t) => {
  const dataDir = path.join(process.cwd(), "data", `test_auth_${Date.now()}_${crypto.randomBytes(4).toString("hex")}`);
  fs.mkdirSync(dataDir, { recursive: true });

  const router = authRouter({ dataDir, appBaseUrl: "http://localhost:3000" });

  const originalAllowlist = process.env.ALLOWLIST_EMAILS;
  const originalPaid = process.env.PAID_MODE;
  process.env.PAID_MODE = "1";
  process.env.ALLOWLIST_EMAILS = "test@example.com";

  try {
    let token: string | undefined;

    // 1. Request Link
    await new Promise<void>((resolve, reject) => {
      const req = makeMockRequest("POST", "/request-link", { email: "test@example.com" });
      const res = makeMockResponse((status, data) => {
        try {
          assert.strictEqual(status, 200);
          assert.deepStrictEqual(data, { ok: true });
          resolve();
        } catch (e) {
          reject(e);
        }
      });
      // simulate routing
      (router as any).handle(req, res, () => reject(new Error("Route not matched")));
    });

    // 2. Verify storage
    const tokensJsonPath = path.join(dataDir, "auth", "tokens.json");
    assert.ok(fs.existsSync(tokensJsonPath), "tokens.json should exist");
    const tokens = JSON.parse(fs.readFileSync(tokensJsonPath, "utf8"));
    assert.strictEqual(tokens.length, 1);

    assert.ok(!("token" in tokens[0]), "Plaintext token should not be stored");
    assert.ok("tokenHash" in tokens[0], "tokenHash should be stored");
    assert.strictEqual(typeof tokens[0].tokenHash, "string");
    assert.strictEqual(tokens[0].tokenHash.length, 64); // SHA-256 length in hex

    // 3. Extract token from outbox
    const outboxDir = path.join(dataDir, "outbox");
    const files = fs.readdirSync(outboxDir);
    assert.strictEqual(files.length, 1);
    const emailBody = fs.readFileSync(path.join(outboxDir, files[0]), "utf8");
    const match = emailBody.match(/token=([^&\s]+)/);
    assert.ok(match, "Token should be in the email outbox");
    token = decodeURIComponent(match[1]);

    // 4. Verify link
    await new Promise<void>((resolve, reject) => {
      const req = makeMockRequest("GET", "/verify", undefined, { token });
      const res = makeMockResponse((status, data, headers) => {
        try {
          assert.strictEqual(status, 302);
          assert.ok(headers.location.includes("/ui/welcome?tenantId="));
          resolve();
        } catch (e) {
          reject(e);
        }
      });
      (router as any).handle(req, res, () => reject(new Error("Route not matched")));
    });

  } finally {
    process.env.ALLOWLIST_EMAILS = originalAllowlist;
    process.env.PAID_MODE = originalPaid;
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});
