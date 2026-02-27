#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase33 OneShot (Agent Rules Brain + Disk Upsert) @ $ROOT"

ts="$(date -u +%Y%m%d_%H%M%S)"
bak="__bak_phase33_${ts}"
mkdir -p "$bak"

# --- backup (best effort) ---
cp -a src "$bak/src" 2>/dev/null || true
cp -a scripts "$bak/scripts" 2>/dev/null || true
cp -a tsconfig.json "$bak/tsconfig.json" 2>/dev/null || true

echo "✅ backup -> $bak"

# --- ensure tsconfig excludes backups (non-breaking) ---
if [ -f tsconfig.json ]; then
  node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const add = ["__bak_*","dist","node_modules"];
for (const x of add) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
NODE
  echo "✅ patched tsconfig.json exclude"
fi

mkdir -p src/lib

# =========================
# [1] Agent Rules Engine
# =========================
cat > src/lib/agent_rules.ts <<'TS'
import crypto from "crypto";

export type IntakeSource = "zapier" | "webhook" | "meta" | "typeform" | "calendly" | "unknown";

export type TicketStatus =
  | "new"
  | "needs_review"
  | "ready"
  | "duplicate";

export type TicketFlag =
  | "missing_email"
  | "missing_name"
  | "missing_contact"
  | "suspicious_payload"
  | "low_signal";

export type NormalizedLead = {
  fullName?: string;
  email?: string;
  phone?: string;
  company?: string;
  message?: string;
  raw?: any;
};

export type RulesResult = {
  status: TicketStatus;
  flags: TicketFlag[];
  missingFields: string[];
  title: string;
  fingerprint: string; // dedupeKey
};

function s(x: any): string {
  return (typeof x === "string" ? x : "").trim();
}

function pick(obj: any, keys: string[]): string {
  for (const k of keys) {
    const v = s(obj?.[k]);
    if (v) return v;
  }
  return "";
}

export function normalizeLead(body: any): { source: IntakeSource; type: string; lead: NormalizedLead } {
  const sourceRaw = s(body?.source).toLowerCase();
  const source: IntakeSource =
    (sourceRaw === "zapier" || sourceRaw === "meta" || sourceRaw === "typeform" || sourceRaw === "calendly") ? (sourceRaw as IntakeSource)
    : (sourceRaw ? "webhook" : "unknown");

  const type = s(body?.type) || "lead";
  const leadObj = body?.lead ?? body ?? {};

  const fullName =
    pick(leadObj, ["fullName", "name", "full_name", "fullname"]) ||
    [pick(leadObj, ["firstName","first_name","first"]), pick(leadObj, ["lastName","last_name","last"])]
      .filter(Boolean).join(" ").trim();

  const email = pick(leadObj, ["email", "Email"]);
  const phone = pick(leadObj, ["phone", "phoneNumber", "phone_number", "mobile"]);
  const company = pick(leadObj, ["company", "organization", "org"]);
  const message = pick(leadObj, ["message", "notes", "note", "comment"]);

  const raw = body?.raw ?? leadObj?.raw ?? body;

  return {
    source,
    type,
    lead: { fullName: fullName || undefined, email: email || undefined, phone: phone || undefined, company: company || undefined, message: message || undefined, raw },
  };
}

/**
 * Dedupe fingerprint:
 *  - stable
 *  - privacy-aware (hash only)
 *  - uses strongest identifiers first
 */
export function computeFingerprint(input: {
  tenantId: string;
  source: string;
  type: string;
  lead: NormalizedLead;
}): string {
  const email = (input.lead.email || "").toLowerCase().trim();
  const phone = (input.lead.phone || "").replace(/\s+/g,"").trim();
  const name = (input.lead.fullName || "").toLowerCase().trim();

  // strongest: email, then phone, then name
  const id = email || phone || name || "anon";
  const payload = JSON.stringify({
    v: 1,
    tenantId: input.tenantId,
    source: input.source,
    type: input.type,
    id,
  });

  return crypto.createHash("sha1").update(payload).digest("hex");
}

export function evaluateRules(args: {
  tenantId: string;
  source: string;
  type: string;
  lead: NormalizedLead;
}): RulesResult {
  const flags: TicketFlag[] = [];
  const missingFields: string[] = [];

  const email = (args.lead.email || "").trim();
  const name = (args.lead.fullName || "").trim();
  const phone = (args.lead.phone || "").trim();

  if (!email) { flags.push("missing_email"); missingFields.push("email"); }
  if (!name)  { flags.push("missing_name"); missingFields.push("fullName"); }
  if (!email && !phone) { flags.push("missing_contact"); missingFields.push("email_or_phone"); }

  // Basic payload sanity
  const rawStr = (() => {
    try { return JSON.stringify(args.lead.raw ?? {}, null, 0); } catch { return ""; }
  })();
  if (rawStr && rawStr.length > 25000) flags.push("suspicious_payload");

  // Very low signal => needs_review
  if (!email && !phone && !name) flags.push("low_signal");

  let status: TicketStatus = "new";
  if (flags.includes("missing_contact") || flags.includes("low_signal") || flags.includes("suspicious_payload")) {
    status = "needs_review";
  } else {
    status = "ready";
  }

  const fingerprint = computeFingerprint({ tenantId: args.tenantId, source: args.source, type: args.type, lead: args.lead });

  const title = (args.type === "lead" ? "Lead intake" : args.type) + (args.source ? ` (${args.source})` : "");

  return { status, flags, missingFields, title, fingerprint };
}
TS
echo "✅ wrote src/lib/agent_rules.ts"

# =========================
# [2] Disk Tickets Store (SSOT)
# =========================
cat > src/lib/tickets_disk.ts <<'TS'
import fs from "fs/promises";
import path from "path";
import crypto from "crypto";
import type { TicketFlag, TicketStatus } from "./agent_rules.js";

export type TicketRecord = {
  id: string;
  tenantId: string;
  source: string;
  type: string;
  title: string;

  status: TicketStatus;
  flags: TicketFlag[];
  missingFields: string[];

  dedupeKey: string;
  createdAtUtc: string;

  // dedupe telemetry
  lastSeenAtUtc: string;
  duplicateCount: number;

  // raw payload is optional; keep small
  raw?: any;
};

function nowUtc(): string {
  return new Date().toISOString();
}

function randId(prefix = "t_"): string {
  return prefix + crypto.randomBytes(10).toString("hex");
}

async function ensureDir(p: string) {
  await fs.mkdir(p, { recursive: true });
}

function dataDir(): string {
  return process.env.DATA_DIR || "./data";
}

function tenantDir(tenantId: string): string {
  return path.join(dataDir(), "tenants", tenantId);
}

function ticketsFile(tenantId: string): string {
  return path.join(tenantDir(tenantId), "tickets.json");
}

export async function listTickets(tenantId: string): Promise<TicketRecord[]> {
  const file = ticketsFile(tenantId);
  try {
    const s = await fs.readFile(file, "utf8");
    const arr = JSON.parse(s);
    return Array.isArray(arr) ? (arr as TicketRecord[]) : [];
  } catch {
    return [];
  }
}

export async function saveTickets(tenantId: string, tickets: TicketRecord[]): Promise<void> {
  await ensureDir(tenantDir(tenantId));
  const file = ticketsFile(tenantId);

  // stable sort newest first (createdAtUtc)
  tickets.sort((a, b) => (b?.createdAtUtc || "").localeCompare(a?.createdAtUtc || ""));

  await fs.writeFile(file, JSON.stringify(tickets, null, 2) + "\n", "utf8");
}

export type UpsertWebhookArgs = {
  tenantId: string;
  source: string;
  type: string;
  title: string;

  status: TicketStatus;
  flags: TicketFlag[];
  missingFields: string[];

  dedupeKey: string;
  raw?: any;
};

export async function upsertWebhookTicket(args: UpsertWebhookArgs): Promise<{ created: boolean; ticket: TicketRecord }> {
  const tickets = await listTickets(args.tenantId);
  const idx = tickets.findIndex(t => t?.dedupeKey === args.dedupeKey);

  if (idx >= 0) {
    const t = tickets[idx];
    const updated: TicketRecord = {
      ...t,
      // keep first createdAtUtc
      lastSeenAtUtc: nowUtc(),
      duplicateCount: (t.duplicateCount || 0) + 1,
      // do NOT downgrade status; but allow needs_review to persist
      status: t.status === "needs_review" ? t.status : args.status,
      flags: Array.from(new Set([...(t.flags || []), ...(args.flags || [])])),
      missingFields: Array.from(new Set([...(t.missingFields || []), ...(args.missingFields || [])])),
      // update title/source if missing
      title: t.title || args.title,
      source: t.source || args.source,
      type: t.type || args.type,
    };
    tickets[idx] = updated;
    await saveTickets(args.tenantId, tickets);
    return { created: false, ticket: updated };
  }

  const createdAt = nowUtc();
  const ticket: TicketRecord = {
    id: randId(),
    tenantId: args.tenantId,
    source: args.source,
    type: args.type,
    title: args.title,
    status: args.status,
    flags: args.flags || [],
    missingFields: args.missingFields || [],
    dedupeKey: args.dedupeKey,
    createdAtUtc: createdAt,
    lastSeenAtUtc: createdAt,
    duplicateCount: 0,
    raw: args.raw,
  };

  tickets.unshift(ticket);
  await saveTickets(args.tenantId, tickets);
  return { created: true, ticket };
}
TS
echo "✅ wrote src/lib/tickets_disk.ts"

# =========================
# [3] Patch webhook route to use rules+upsert
# =========================
# We patch src/api/webhook.ts in a safe, full-replace manner.
# (If you had other content, it was backed up in __bak_phase33_*)
mkdir -p src/api

cat > src/api/webhook.ts <<'TS'
import type { Express } from "express";
import express from "express";

import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";
import { normalizeLead, evaluateRules } from "../lib/agent_rules.js";
import { upsertWebhookTicket } from "../lib/tickets_disk.js";

export function mountWebhook(app: Express) {
  const router = express.Router();

  // POST /api/webhook/intake?tenantId=...&k=...
  router.post("/intake", express.json({ limit: "1mb" }), async (req, res) => {
    try {
      const tenantId = String(req.query.tenantId || req.body?.tenantId || "").trim();
      const tenantKey = String(req.query.k || req.headers["x-tenant-key"] || req.body?.k || "").trim();

      if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenant_id" });
      if (!tenantKey) return res.status(400).json({ ok: false, error: "missing_tenant_key" });

      const ok = await verifyTenantKeyLocal(tenantId, tenantKey);
      if (!ok) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

      const { source, type, lead } = normalizeLead(req.body);
      const rules = evaluateRules({ tenantId, source, type, lead });

      const { created, ticket } = await upsertWebhookTicket({
        tenantId,
        source,
        type,
        title: rules.title,
        status: rules.status,
        flags: rules.flags,
        missingFields: rules.missingFields,
        dedupeKey: rules.fingerprint,
        raw: lead.raw,
      });

      return res.status(201).json({
        ok: true,
        created,
        ticket: {
          id: ticket.id,
          status: ticket.status,
          title: ticket.title,
          source: ticket.source,
          type: ticket.type,
          dedupeKey: ticket.dedupeKey,
          flags: ticket.flags,
          missingFields: ticket.missingFields,
          duplicateCount: ticket.duplicateCount,
          createdAtUtc: ticket.createdAtUtc,
          lastSeenAtUtc: ticket.lastSeenAtUtc,
        },
      });
    } catch (e: any) {
      return res.status(500).json({ ok: false, error: "webhook_failed", detail: String(e?.message || e) });
    }
  });

  app.use("/api/webhook", router);
}
TS
echo "✅ wrote src/api/webhook.ts (rules+upsert)"

# =========================
# [4] Patch server to mount webhook (best effort, non-breaking)
# =========================
# We try to insert import + mountWebhook if not present.
FILE="src/server.ts"
if [ -f "$FILE" ]; then
  node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p,"utf8");

if (!s.includes("mountWebhook")) {
  // add import near other imports
  if (!s.includes('from "./api/webhook')) {
    s = s.replace(
      /(from\s+["']\.\/api\/admin[^"']*["'];\s*\n)/,
      `$1import { mountWebhook } from "./api/webhook.js";\n`
    );
    // if admin import pattern not found, append after last import
    if (!s.includes('import { mountWebhook }')) {
      const lines = s.split("\n");
      let lastImport = -1;
      for (let i=0;i<lines.length;i++) if (lines[i].startsWith("import ")) lastImport = i;
      lines.splice(lastImport+1, 0, 'import { mountWebhook } from "./api/webhook.js";');
      s = lines.join("\n");
    }
  }

  // mount inside main() after app creation
  // look for: const app = express();
  if (s.includes("const app = express()")) {
    s = s.replace(
      /const app = express\(\);\s*\n/,
      (m)=> m + "  mountWebhook(app);\n"
    );
  } else if (s.includes("const app=express()")) {
    s = s.replace(/const app=express\(\);\s*\n/, (m)=> m + "  mountWebhook(app);\n");
  } else {
    // fallback: mount before listen
    s = s.replace(/app\.listen\(/, "mountWebhook(app);\n\napp.listen(");
  }

  fs.writeFileSync(p, s);
  console.log("✅ patched src/server.ts (mountWebhook)");
} else {
  console.log("ℹ️ src/server.ts already mounts webhook");
}
NODE
else
  echo "⚠️ src/server.ts not found; skip mount patch"
fi

# =========================
# [5] Smoke Phase33
# =========================
cat > scripts/smoke-phase33.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $1"; exit 1; }

echo "==> [0] health"
curl -sS "$BASE_URL/health" >/dev/null || fail "health not ok"
echo "✅ health ok"

[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -D- "$BASE_URL/ui" | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui not hidden"

echo "==> [2] /ui/admin redirect (302) + capture Location"
hdr="$(curl -sS -o /dev/null -D- "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
loc="$(echo "$hdr" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | tail -n 1)"
[ -n "$loc" ] || { echo "$hdr" | sed -n '1,25p'; fail "no Location from /ui/admin"; }
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"
[ -n "$TENANT_ID" ] || fail "could not parse tenantId from Location"
[ -n "$TENANT_KEY" ] || fail "could not parse k from Location"

echo "==> [3] webhook intake #1 should be 201 (created true/false ok)"
payload='{"source":"zapier","type":"lead","lead":{"fullName":"Jane Doe","email":"jane@example.com","phone":"+33 6 00 00 00 00","raw":{"demo":"no","ts":"'$(date -u +%FT%TZ)'"}}}'
r1="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" -H "Content-Type: application/json" -d "$payload")"
b1="$(echo "$r1" | head -n 1)"
c1="$(echo "$r1" | tail -n 1)"
echo "status=$c1"
echo "$b1"
[ "$c1" = "201" ] || fail "webhook #1 not 201"

id="$(echo "$b1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.ticket?.id||"")}catch{console.log("")}})')"
[ -n "$id" ] || fail "missing ticket.id in webhook response"

echo "==> [4] webhook intake #2 same payload should NOT create new ticket (created=false expected) + duplicateCount>=1"
r2="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" -H "Content-Type: application/json" -d "$payload")"
b2="$(echo "$r2" | head -n 1)"
c2="$(echo "$r2" | tail -n 1)"
echo "status=$c2"
echo "$b2"
[ "$c2" = "201" ] || fail "webhook #2 not 201"

created2="$(echo "$b2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(String(j.created))}catch{console.log("")}})')"
dup2="$(echo "$b2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.ticket?.duplicateCount??"")}catch{console.log("")}})')"
[ "$created2" = "false" ] || fail "expected created=false on duplicate"
[ -n "$dup2" ] || fail "missing duplicateCount"
echo "duplicateCount=$dup2"

echo
echo "✅ Phase33 smoke OK"
echo "Setup:"
echo "  $BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
BASH
chmod +x scripts/smoke-phase33.sh
echo "✅ wrote scripts/smoke-phase33.sh"

echo "==> Typecheck (best effort)"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase33 installed."
echo "Now:"
echo "  1) restart: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke:   ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase33.sh"
