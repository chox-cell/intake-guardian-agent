
import { test, after, before } from "node:test";
import assert from "node:assert";
import fs from "node:fs";
import path from "node:path";
import express from "express";
import http from "node:http";
import { authRouter } from "./auth";

test("auth_security_repro", async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(process.cwd(), "auth_test_"));
  const app = express();
  app.use(express.json());

  // Mount auth router with the temp data dir
  app.use("/api/auth", authRouter({ dataDir: tmpDir }));

  let server: http.Server;
  let port: number;

  await new Promise<void>((resolve) => {
    server = app.listen(0, () => {
      port = (server.address() as any).port;
      resolve();
    });
  });

  const baseUrl = `http://localhost:${port}`;

  try {
    // 1. Request a link
    const res1 = await fetch(`${baseUrl}/api/auth/request-link`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email: "test@example.com" }),
    });

    assert.strictEqual(res1.status, 200, "Should return 200 OK");
    const json1 = await res1.json();
    assert.strictEqual(json1.ok, true);

    // 2. Find the token in the outbox
    const outboxDir = path.join(tmpDir, "outbox");
    const files = fs.readdirSync(outboxDir);
    assert.ok(files.length > 0, "Should have created an outbox file");

    const mailContent = fs.readFileSync(path.join(outboxDir, files[0]), "utf8");
    // Extract token from link: .../verify?token=...
    const match = mailContent.match(/token=([a-zA-Z0-9_-]+)/);
    assert.ok(match, "Token should be present in email");
    const emailToken = match![1];

    // 3. Check tokens.json
    const tokensPath = path.join(tmpDir, "auth", "tokens.json");
    assert.ok(fs.existsSync(tokensPath), "tokens.json should exist");
    const tokens = JSON.parse(fs.readFileSync(tokensPath, "utf8"));

    assert.ok(Array.isArray(tokens), "tokens.json should contain an array");
    assert.ok(tokens.length > 0, "Should have at least one token record");

    const record = tokens[0];

    // SECURITY CHECK: The stored record should NOT contain the plain token
    assert.strictEqual(record.token, undefined, "Plain token should NOT be stored");
    assert.ok(record.tokenHash, "Token hash SHOULD be stored");
    assert.notStrictEqual(record.tokenHash, emailToken, "Stored hash must NOT equal plain token");

    // 4. Verify functionality
    const res2 = await fetch(`${baseUrl}/api/auth/verify?token=${emailToken}`, {
        method: "GET",
        redirect: "manual"
    });

    // It redirects on success (302)
    assert.strictEqual(res2.status, 302, "Verify should redirect on success");

  } finally {
    server!.close();
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
