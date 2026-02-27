#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$PWD}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_v8_1_server_ssot_intake_easy"
mkdir -p "$BK"

echo "============================================================"
echo "OneShot: v8.1 — server.ts SSOT intake/easy + JSON parse + fix dup imports"
echo "Repo: $REPO"
echo "Backup: $BK"
echo "============================================================"

cp -a src/server.ts "$BK/server.ts"

node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const file = path.join(process.cwd(), "src/server.ts");
let s = fs.readFileSync(file, "utf8");

/**
 * 1) Fix duplicate express type imports
 * Keep only ONE: import type { Request, Response, NextFunction } from "express";
 * Remove any other import type { Request, Response } from "express";
 */
s = s.replace(/^import type \{ Request,\s*Response \} from "express";\s*\n/gm, "");

// If there are multiple lines with Request/Response/NextFunction, normalize to single line.
const typeLines = s.match(/^import type \{[^}]*\} from "express";\s*$/gm) || [];
if (typeLines.length > 1) {
  // remove all express type imports then insert canonical one after first import line
  s = s.replace(/^import type \{[^}]*\} from "express";\s*\n?/gm, "");
  // insert after first non-empty import
  const lines = s.split("\n");
  let idx = 0;
  while (idx < lines.length && !lines[idx].startsWith("import ")) idx++;
  lines.splice(idx + 1, 0, 'import type { Request, Response, NextFunction } from "express";');
  s = lines.join("\n");
} else if (!s.match(/^import type \{ Request,\s*Response,\s*NextFunction \} from "express";/m)) {
  // ensure canonical import exists (if none exists)
  s = s.replace(/^import\s+express\s+from\s+"express";\s*$/m, (m) => m + '\nimport type { Request, Response, NextFunction } from "express";');
}

/**
 * 2) Ensure we have `const app = express()` and immediately after it: JSON middleware (2mb)
 * (We do route-level json too, but this stabilizes everything.)
 */
s = s.replace(/const\s+app\s*=\s*express\(\)\s*\n/,(m)=> m + `\n// GOLD: parse JSON early (SSOT)\napp.use(express.json({ limit: "2mb" }));\napp.use(express.urlencoded({ extended: true }));\n\n`);

/**
 * 3) Insert SSOT routes (intake/easy/send-test-lead) only once.
 * We insert after the early JSON middleware block.
 */
const marker = "/* GOLD_SSOT_WEBHOOK_ROUTES_V8 */";
if (!s.includes(marker)) {
  s = s.replace(
    /app\.use\(express\.urlencoded\(\{ extended: true \}\)\);\s*\n\s*\n/s,
    (m) => m + `${marker}\n` +
`function __loadTenantKeysMap(): Record<string,string> {
  try {
    const raw = process.env.TENANT_KEYS || process.env.TENANT_KEYS_JSON || "";
    if (!raw) return {};
    const arr = JSON.parse(raw);
    const out: Record<string,string> = {};
    if (Array.isArray(arr)) {
      for (const it of arr) {
        if (it && typeof it.tenantId === "string" && typeof it.tenantKey === "string") {
          out[it.tenantId] = it.tenantKey;
        }
      }
    }
    return out;
  } catch {
    return {};
  }
}

function __validTenantKey(tenantId: string, key: string) {
  if (!tenantId || !key) return false;
  const map = __loadTenantKeysMap();
  const expected = map[tenantId];
  if (!expected) return false;
  return expected === key;
}

function __missingLeadFields(lead: any) {
  const missing: string[] = [];
  const fullName = String(lead?.fullName || "").trim();
  const email = String(lead?.email || "").trim();
  const phone = String(lead?.phone || lead?.mobile || "").trim();
  if (!email) missing.push("email");
  if (!fullName) missing.push("fullName");
  if (!email && !phone) missing.push("email_or_phone");
  return { fullName, email, phone, missing };
}

function __dedupeKey(type: string, email: string, phone: string) {
  // deterministic + stable
  const base = [String(type||""), String(email||""), String(phone||"")].join("|").toLowerCase();
  return crypto.createHash("sha1").update(base).digest("hex");
}

/**
 * SSOT: /api/webhook/intake
 * - validates tenantId + key
 * - writes to ticket-store (upsertTicket)
 * - returns the created/updated ticket
 */
app.post("/api/webhook/intake", (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const key = String(req.headers["x-tenant-key"] || q.k || q.key || "").trim();

  if (!tenantId) return res.status(400).json({ ok:false, error:"missing_tenantId" });
  if (!key) return res.status(401).json({ ok:false, error:"missing_tenant_key" });
  if (!__validTenantKey(tenantId, key)) return res.status(401).json({ ok:false, error:"invalid_tenant_key" });

  const body = req.body || {};
  const type = String(body.type || "lead").trim() || "lead";
  const source = String(body.source || "webhook").trim() || "webhook";
  const lead = body.lead || {};

  const { fullName, email, phone, missing } = __missingLeadFields(lead);

  const flags: string[] = [];
  if (missing.includes("email")) flags.push("missing_email");
  if (missing.includes("fullName")) flags.push("missing_name");
  if (missing.includes("email_or_phone")) flags.push("missing_contact");

  // minimal signal check
  const lowSignal = missing.length > 0;
  if (lowSignal) flags.push("low_signal");

  const dedupeKey = __dedupeKey(type, email, phone);

  const now = new Date().toISOString();
  const ticket = upsertTicket({
    tenantId,
    type,
    source,
    title: "Lead intake (webhook)",
    status: lowSignal ? "needs_review" : "ready",
    dedupeKey,
    flags,
    missingFields: missing,
    createdAtUtc: now,
    lastSeenAtUtc: now
  } as any);

  return res.json({ ok:true, created: true, ticket });
});

/**
 * SSOT: /api/webhook/easy
 * - same validation
 * - forwards payload into /api/webhook/intake logic (direct call)
 */
app.post("/api/webhook/easy", (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const key = String(req.headers["x-tenant-key"] || q.k || q.key || "").trim();
  if (!tenantId) return res.status(400).json({ ok:false, error:"missing_tenantId" });
  if (!key) return res.status(401).json({ ok:false, error:"missing_tenant_key" });
  if (!__validTenantKey(tenantId, key)) return res.status(401).json({ ok:false, error:"invalid_tenant_key" });

  // Reuse same handler path by calling intake route logic style
  // (But no internal fetch; just emulate payload)
  (req as any).query = { tenantId };
  (req as any).headers["x-tenant-key"] = key;

  // Call intake handler by duplicating minimal part:
  const body = req.body || {};
  const type = String(body.type || "lead").trim() || "lead";
  const source = String(body.source || "webhook").trim() || "webhook";
  const lead = body.lead || {};

  const { fullName, email, phone, missing } = __missingLeadFields(lead);

  const flags: string[] = [];
  if (missing.includes("email")) flags.push("missing_email");
  if (missing.includes("fullName")) flags.push("missing_name");
  if (missing.includes("email_or_phone")) flags.push("missing_contact");
  const lowSignal = missing.length > 0;
  if (lowSignal) flags.push("low_signal");

  const dedupeKey = __dedupeKey(type, email, phone);

  const now = new Date().toISOString();
  const ticket = upsertTicket({
    tenantId,
    type,
    source,
    title: "Lead intake (webhook)",
    status: lowSignal ? "needs_review" : "ready",
    dedupeKey,
    flags,
    missingFields: missing,
    createdAtUtc: now,
    lastSeenAtUtc: now
  } as any);

  return res.json({ ok:true, created: true, ticket });
});

/**
 * SSOT: /api/ui/send-test-lead
 */
app.post("/api/ui/send-test-lead", (req: any, res: any) => {
  const q: any = req.query || {};
  const tenantId = String(q.tenantId || "").trim();
  const key = String(q.k || req.headers["x-tenant-key"] || "").trim();
  if (!tenantId) return res.status(400).json({ ok:false, error:"missing_tenantId" });
  if (!key) return res.status(401).json({ ok:false, error:"missing_tenant_key" });
  if (!__validTenantKey(tenantId, key)) return res.status(401).json({ ok:false, error:"invalid_tenant_key" });

  const payload = {
    source: "ui",
    type: "lead",
    lead: { fullName: "UI Test Lead", email: "ui-test@local.dev", company: "DecisionCover" }
  };

  const now = new Date().toISOString();
  const { fullName, email, phone, missing } = __missingLeadFields(payload.lead);

  const flags: string[] = [];
  if (missing.includes("email")) flags.push("missing_email");
  if (missing.includes("fullName")) flags.push("missing_name");
  if (missing.includes("email_or_phone")) flags.push("missing_contact");
  const lowSignal = missing.length > 0;
  if (lowSignal) flags.push("low_signal");

  const dedupeKey = __dedupeKey("lead", email, phone);

  const ticket = upsertTicket({
    tenantId,
    type: "lead",
    source: "ui",
    title: "Lead intake (webhook)",
    status: lowSignal ? "needs_review" : "ready",
    dedupeKey,
    flags,
    missingFields: missing,
    createdAtUtc: now,
    lastSeenAtUtc: now
  } as any);

  return res.json({ ok:true, created:true, ticket });
});
\n`
  );
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: src/server.ts (v8.1 SSOT routes + JSON + dup-import fix)");
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ v8.1 applied"
echo "Backup: $BK"
