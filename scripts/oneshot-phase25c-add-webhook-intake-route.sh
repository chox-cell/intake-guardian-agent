#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase25c OneShot (add /api/webhook/intake real route + disk persistence)"

mkdir -p scripts src/api

# -------------------------
# [1] Write webhook route
# -------------------------
cat > src/api/webhook.ts <<'TS'
import type { Request, Response } from "express";
import express from "express";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";

function nowUtc() {
  return new Date().toISOString();
}

function escJson(s: string) {
  // safe minimal (for logs only)
  return s.replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
}

function getTenantId(req: Request): string {
  return (
    (req.query.tenantId as string) ||
    (req.headers["x-tenant-id"] as string) ||
    (req.body && (req.body.tenantId as string)) ||
    ""
  );
}

function getTenantKey(req: Request): string {
  return (
    (req.query.k as string) ||
    (req.headers["x-tenant-key"] as string) ||
    (req.body && (req.body.tenantKey as string)) ||
    ""
  );
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function writeJsonl(filePath: string, obj: any) {
  const line = escJson(JSON.stringify(obj)) + "\n";
  fs.appendFileSync(filePath, line, { encoding: "utf8" });
}

export function mountWebhook(app: express.Express) {
  const router = express.Router();

  // POST /api/webhook/intake
  router.post("/intake", express.json({ limit: "256kb" }), async (req: Request, res: Response) => {
    try {
      const tenantId = getTenantId(req);
      const tenantKey = getTenantKey(req);

      if (!tenantId || !tenantKey) {
        return res.status(400).json({ ok: false, error: "missing_tenant_id_or_key" });
      }
      const ok = await verifyTenantKeyLocal(tenantId, tenantKey);
      if (!ok) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

      const id = "tkt_" + crypto.randomBytes(9).toString("hex");
      const payload = (req.body && typeof req.body === "object") ? req.body : {};

      // minimal normalized ticket (real data)
      const ticket = {
        id,
        tenantId,
        title: payload.title || "Webhook Ticket",
        body: payload.body || "",
        customer: payload.customer || null,
        meta: payload.meta || null,
        status: payload.status || "open",
        createdAtUtc: nowUtc(),
        source: "webhook",
      };

      const dataDir = process.env.DATA_DIR || "./data";
      const base = path.resolve(dataDir, "tenants", tenantId);
      ensureDir(base);

      // append ticket
      writeJsonl(path.join(base, "tickets.jsonl"), ticket);

      return res.status(201).json({ ok: true, id });
    } catch (e: any) {
      return res.status(500).json({ ok: false, error: "webhook_failed", hint: String(e?.message || e) });
    }
  });

  app.use("/api/webhook", router);
}
TS

echo "✅ wrote src/api/webhook.ts"

# -------------------------
# [2] Patch server.ts to mountWebhook(app)
#     - Safe: insert import + call after app is created
# -------------------------
node <<'NODE'
const fs = require("fs");

const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// add import if missing
if (!s.includes('mountWebhook')) {
  // place near other imports
  const lines = s.split("\n");
  let insertAt = 0;
  for (let i=0;i<lines.length;i++){
    if (lines[i].startsWith("import ")) insertAt = i+1;
  }
  lines.splice(insertAt, 0, 'import { mountWebhook } from "./api/webhook.js";');
  s = lines.join("\n");
}

// add call if missing
if (!s.includes("mountWebhook(app")) {
  // try to insert after app creation. Common patterns: const app = express();
  const idx = s.search(/const\s+app\s*=\s*express\(\)\s*;?/);
  if (idx === -1) {
    console.error("❌ Could not find 'const app = express()' in src/server.ts. Patch manually: call mountWebhook(app) after app is created.");
    process.exit(1);
  }
  // insert after that line
  const lines = s.split("\n");
  let lineNo = lines.findIndex(l => /const\s+app\s*=\s*express\(\)\s*;?/.test(l));
  lines.splice(lineNo+1, 0, "mountWebhook(app as any);");
  s = lines.join("\n");
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (import + mountWebhook)");
NODE

# -------------------------
# [3] Typecheck (best effort)
# -------------------------
if pnpm -s lint:types >/dev/null 2>&1; then
  echo "==> Typecheck"
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase25c installed."
echo "Now:"
echo "  1) (restart) pnpm dev"
echo "  2) TENANT_ID=tenant_demo TENANT_KEY=YOUR_REAL_KEY BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-webhook.sh"
echo
