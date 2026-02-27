#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase25d_${TS}"
echo "==> Phase25d OneShot (unify DATA_DIR + single SSOT registry + webhook auth fix) @ $ROOT"
mkdir -p "$BAK"
cp -R src scripts tsconfig.json package.json "$BAK/" >/dev/null 2>&1 || true
echo "✅ backup -> $BAK"

# -------------------------
# [1] tsconfig: ignore backups
# -------------------------
if [ -f tsconfig.json ]; then
  node <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "__bak_phase*"]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE
fi

# -------------------------
# [2] Write SSOT registry (single source of truth)
#     - Absolute DATA_DIR
#     - Tenants stored in: ${DATA_DIR}/tenants/registry.json
# -------------------------
mkdir -p src/lib
cat > src/lib/tenant_registry.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TenantRecord = {
  tenantId: string;
  tenantKey: string;
  notes?: string;
  createdAtUtc: string;
  updatedAtUtc: string;
};

function nowUtc() {
  return new Date().toISOString();
}

function resolveDataDir(input?: string) {
  const v = (input || process.env.DATA_DIR || "./data").trim();
  return path.resolve(v);
}

function tenantsDir(dataDirAbs: string) {
  return path.join(dataDirAbs, "tenants");
}

function registryPath(dataDirAbs: string) {
  return path.join(tenantsDir(dataDirAbs), "registry.json");
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function randId() {
  return "tenant_" + Date.now() + "_" + crypto.randomBytes(6).toString("hex");
}

function randKey(len = 24) {
  // URL-safe
  return crypto.randomBytes(Math.ceil(len * 0.75)).toString("base64url").slice(0, len);
}

function readRegistry(dataDirAbs: string): TenantRecord[] {
  try {
    const p = registryPath(dataDirAbs);
    if (!fs.existsSync(p)) return [];
    const raw = fs.readFileSync(p, "utf8");
    const j = JSON.parse(raw);
    return Array.isArray(j) ? (j as TenantRecord[]) : [];
  } catch {
    return [];
  }
}

function writeRegistry(dataDirAbs: string, tenants: TenantRecord[]) {
  ensureDir(tenantsDir(dataDirAbs));
  fs.writeFileSync(registryPath(dataDirAbs), JSON.stringify(tenants, null, 2) + "\n");
}

export function getDataDirAbs() {
  return resolveDataDir();
}

export async function listTenants(dataDir?: string): Promise<TenantRecord[]> {
  const abs = resolveDataDir(dataDir);
  return readRegistry(abs);
}

export async function getTenant(dataDir: string, tenantId: string): Promise<TenantRecord | null> {
  const abs = resolveDataDir(dataDir);
  const all = readRegistry(abs);
  return all.find(t => t.tenantId === tenantId) || null;
}

export async function createTenant(dataDirOrNotes?: string, maybeNotes?: string): Promise<TenantRecord> {
  // Backward compatible:
  // - createTenant("Some notes")  => uses DATA_DIR + notes
  // - createTenant(dataDirAbs, "notes") => uses provided dataDirAbs
  const isAbsDir = (v?: string) => !!v && (v.startsWith("/") || v.includes(":\\"));
  const dataDir = isAbsDir(dataDirOrNotes) ? (dataDirOrNotes as string) : resolveDataDir();
  const notes = isAbsDir(dataDirOrNotes) ? (maybeNotes || "") : (dataDirOrNotes || "");

  const all = readRegistry(dataDir);
  const t: TenantRecord = {
    tenantId: randId(),
    tenantKey: randKey(32),
    notes,
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
  };
  all.unshift(t);
  writeRegistry(dataDir, all);
  return t;
}

export async function rotateTenantKey(dataDir: string, tenantId: string): Promise<TenantRecord | null> {
  const abs = resolveDataDir(dataDir);
  const all = readRegistry(abs);
  const idx = all.findIndex(t => t.tenantId === tenantId);
  if (idx === -1) return null;
  all[idx] = { ...all[idx], tenantKey: randKey(32), updatedAtUtc: nowUtc() };
  writeRegistry(abs, all);
  return all[idx];
}

/**
 * verifyTenantKeyLocal(tenantId, tenantKey)
 * verifyTenantKeyLocal(tenantId, tenantKey, dataDirAbs)
 */
export async function verifyTenantKeyLocal(
  tenantId: string,
  tenantKey: string,
  dataDir?: string
): Promise<boolean> {
  if (!tenantId || !tenantKey) return false;
  const abs = resolveDataDir(dataDir);
  const t = readRegistry(abs).find(x => x.tenantId === tenantId);
  if (!t) return false;

  // constant-time compare
  const a = Buffer.from(String(t.tenantKey));
  const b = Buffer.from(String(tenantKey));
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

export async function getOrCreateDemoTenant(dataDir?: string): Promise<TenantRecord> {
  const abs = resolveDataDir(dataDir);
  const DEMO_ID = "tenant_demo";
  const all = readRegistry(abs);
  const found = all.find(t => t.tenantId === DEMO_ID);
  if (found) return found;

  const t: TenantRecord = {
    tenantId: DEMO_ID,
    tenantKey: randKey(32),
    notes: "Demo tenant (local)",
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
  };
  all.unshift(t);
  writeRegistry(abs, all);
  return t;
}
TS
echo "✅ wrote src/lib/tenant_registry.ts"

# -------------------------
# [3] Patch webhook to verify against SAME registry + SAME DATA_DIR
# -------------------------
mkdir -p src/api
cat > src/api/webhook.ts <<'TS'
import type { Request, Response } from "express";
import express from "express";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { verifyTenantKeyLocal, getDataDirAbs } from "../lib/tenant_registry.js";

function nowUtc() {
  return new Date().toISOString();
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

function appendJsonl(filePath: string, obj: any) {
  fs.appendFileSync(filePath, JSON.stringify(obj) + "\n", "utf8");
}

export function mountWebhook(app: express.Express) {
  const router = express.Router();

  // POST /api/webhook/intake
  router.post(
    "/intake",
    express.json({ limit: "256kb" }),
    async (req: Request, res: Response) => {
      try {
        const dataDirAbs = getDataDirAbs();
        const tenantId = getTenantId(req);
        const tenantKey = getTenantKey(req);

        if (!tenantId || !tenantKey) {
          return res.status(400).json({ ok: false, error: "missing_tenant_id_or_key" });
        }

        const ok = await verifyTenantKeyLocal(tenantId, tenantKey, dataDirAbs);
        if (!ok) return res.status(401).json({ ok: false, error: "invalid_tenant_key" });

        const payload = req.body && typeof req.body === "object" ? req.body : {};
        const id = "tkt_" + crypto.randomBytes(9).toString("hex");

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

        const base = path.join(dataDirAbs, "tenants", tenantId);
        ensureDir(base);
        appendJsonl(path.join(base, "tickets.jsonl"), ticket);

        return res.status(201).json({ ok: true, id });
      } catch (e: any) {
        return res.status(500).json({
          ok: false,
          error: "webhook_failed",
          hint: String(e?.message || e),
        });
      }
    }
  );

  app.use("/api/webhook", router);
}
TS
echo "✅ wrote src/api/webhook.ts"

# -------------------------
# [4] Patch UI routes:
#     - /ui/admin autolink uses demo tenant from registry (same DATA_DIR abs)
#     - /ui/tickets reads tickets.jsonl from SAME DATA_DIR abs
#     - /ui/export.csv same
# -------------------------
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import fs from "node:fs";
import path from "node:path";
import { getDataDirAbs, getOrCreateDemoTenant, verifyTenantKeyLocal } from "../lib/tenant_registry.js";

function esc(s: string) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function htmlPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>
<style>
:root { color-scheme: dark; }
body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
.wrap { max-width: 1180px; margin: 56px auto; padding: 0 18px; }
.card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
.h { font-size: 28px; font-weight: 850; margin: 0 0 10px; letter-spacing: .2px; }
.muted { color: #9ca3af; font-size: 13px; }
.row { display:flex; gap:14px; flex-wrap:wrap; align-items:center; }
.btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.25); color:#e5e7eb; text-decoration:none; font-weight:700; }
.btn:hover { border-color: rgba(255,255,255,.18); background: rgba(0,0,0,.34); }
.btn.primary { background: rgba(34,197,94,.16); border-color: rgba(34,197,94,.30); }
.btn.primary:hover { background: rgba(34,197,94,.22); }
table { width:100%; border-collapse: collapse; margin-top: 12px; }
th, td { text-align:left; padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; }
th { color:#9ca3af; font-weight: 800; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
.chip { display:inline-block; padding: 4px 10px; border-radius: 999px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.20); font-weight: 800; font-size: 12px; }
.chip.open { border-color: rgba(59,130,246,.35); background: rgba(59,130,246,.12); }
.chip.pending { border-color: rgba(245,158,11,.35); background: rgba(245,158,11,.12); }
.chip.closed { border-color: rgba(34,197,94,.35); background: rgba(34,197,94,.12); }
.kbd { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size: 12px; padding: 3px 8px; border-radius: 10px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.30); color:#e5e7eb; }
pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
<div class="wrap">${body}</div>
</body>
</html>`;
}

function readTicketsJsonl(dataDirAbs: string, tenantId: string) {
  const file = path.join(dataDirAbs, "tenants", tenantId, "tickets.jsonl");
  if (!fs.existsSync(file)) return [];
  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
  const out: any[] = [];
  for (const ln of lines) {
    try { out.push(JSON.parse(ln)); } catch {}
  }
  return out;
}

function toCsvRow(cols: string[]) {
  const escCsv = (v: string) => `"${String(v).replace(/"/g, '""')}"`;
  return cols.map(escCsv).join(",") + "\n";
}

async function requireTenant(req: Request): Promise<{ tenantId: string; tenantKey: string; dataDirAbs: string } | null> {
  const dataDirAbs = getDataDirAbs();
  const tenantId = (req.query.tenantId as string) || "";
  const tenantKey = (req.query.k as string) || "";
  if (!tenantId || !tenantKey) return null;

  const ok = await verifyTenantKeyLocal(tenantId, tenantKey, dataDirAbs);
  if (!ok) return null;
  return { tenantId, tenantKey, dataDirAbs };
}

export function mountUi(app: Express, _args?: { store?: any }) {
  // Hide root
  app.get("/ui", (_req, res) => res.status(404).send("Not Found"));

  // Admin autolink -> redirects to a tenant UI link (demo tenant)
  app.get("/ui/admin", async (req, res) => {
    try {
      const ADMIN_KEY = process.env.ADMIN_KEY || "";
      const admin = String((req.query.admin as string) || "");
      if (!ADMIN_KEY || admin !== ADMIN_KEY) return res.status(401).send("invalid_admin_key");

      const dataDirAbs = getDataDirAbs();
      const tenant = await getOrCreateDemoTenant(dataDirAbs);

      // Force Location header
      const loc = `/ui/tickets?tenantId=${encodeURIComponent(tenant.tenantId)}&k=${encodeURIComponent(tenant.tenantKey)}`;
      res.setHeader("Location", loc);
      return res.status(302).end();
    } catch (e: any) {
      const body = `<div class="card"><div class="h">Admin error</div><div class="muted">autolink_failed</div><pre>${esc(String(e?.stack || e))}</pre></div>`;
      return res.status(500).send(htmlPage("Admin error", body));
    }
  });

  // Client tickets UI
  app.get("/ui/tickets", async (req, res) => {
    const gate = await requireTenant(req);
    if (!gate) {
      return res.status(401).send(htmlPage("Unauthorized", `<div class="card"><div class="h">Unauthorized</div><div class="muted">invalid_tenant_key</div></div>`));
    }

    const { tenantId, tenantKey, dataDirAbs } = gate;
    const tickets = readTicketsJsonl(dataDirAbs, tenantId).reverse().slice(0, 200);

    const rows = tickets.map(t => {
      const st = String(t.status || "open");
      const chip = st === "closed" ? "closed" : (st === "pending" ? "pending" : "open");
      return `<tr>
        <td><span class="kbd">${esc(String(t.id || ""))}</span></td>
        <td>${esc(String(t.title || ""))}</td>
        <td><span class="chip ${chip}">${esc(st)}</span></td>
        <td class="muted">${esc(String(t.createdAtUtc || ""))}</td>
      </tr>`;
    }).join("");

    const exportUrl = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;

    const body = `
      <div class="card">
        <div class="h">Tickets</div>
        <div class="muted">Tenant: <span class="kbd">${esc(tenantId)}</span></div>
        <div class="row" style="margin-top:12px">
          <a class="btn primary" href="${exportUrl}">Export CSV</a>
          <span class="muted">DATA_DIR: <span class="kbd">${esc(dataDirAbs)}</span></span>
        </div>
        <table>
          <thead><tr><th>ID</th><th>Title</th><th>Status</th><th>Created</th></tr></thead>
          <tbody>${rows || `<tr><td colspan="4" class="muted">No tickets yet. Use webhook intake to create real tickets.</td></tr>`}</tbody>
        </table>
      </div>`;
    return res.status(200).send(htmlPage("Tickets", body));
  });

  // Export CSV (real)
  app.get("/ui/export.csv", async (req, res) => {
    const gate = await requireTenant(req);
    if (!gate) return res.status(401).send("invalid_tenant_key");

    const { tenantId, dataDirAbs } = gate;
    const tickets = readTicketsJsonl(dataDirAbs, tenantId).reverse().slice(0, 500);

    res.setHeader("content-type", "text/csv; charset=utf-8");
    res.write(toCsvRow(["id", "title", "status", "createdAtUtc"]));
    for (const t of tickets) {
      res.write(toCsvRow([String(t.id||""), String(t.title||""), String(t.status||""), String(t.createdAtUtc||"")]));
    }
    return res.end();
  });
}
TS
echo "✅ wrote src/ui/routes.ts"

# -------------------------
# [5] Ensure server mounts UI + webhook (idempotent patch)
# -------------------------
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p,"utf8");

// imports
if (!s.includes('from "./ui/routes.js"') && !s.includes('from "./ui/routes.ts"')) {
  // best effort: insert after last import
  const lines = s.split("\n");
  let insertAt = 0;
  for (let i=0;i<lines.length;i++) if (lines[i].startsWith("import ")) insertAt = i+1;
  lines.splice(insertAt, 0, 'import { mountUi } from "./ui/routes.js";');
  s = lines.join("\n");
}
if (!s.includes('from "./api/webhook.js"')) {
  const lines = s.split("\n");
  let insertAt = 0;
  for (let i=0;i<lines.length;i++) if (lines[i].startsWith("import ")) insertAt = i+1;
  lines.splice(insertAt, 0, 'import { mountWebhook } from "./api/webhook.js";');
  s = lines.join("\n");
}

// ensure mount calls after `const app = express()`
const lines = s.split("\n");
const appLine = lines.findIndex(l => /const\s+app\s*=\s*express\(\)\s*;?/.test(l));
if (appLine === -1) {
  console.error("❌ Could not find `const app = express()` in src/server.ts");
  process.exit(1);
}

const hasWebhook = s.includes("mountWebhook(app");
const hasUi = s.includes("mountUi(app");

let insert = [];
if (!hasWebhook) insert.push("mountWebhook(app as any);");
if (!hasUi) insert.push("mountUi(app as any, { store: (store as any) });");

// insert only once
if (insert.length) {
  lines.splice(appLine+1, 0, ...insert);
  s = lines.join("\n");
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountWebhook + mountUi)");
NODE

# -------------------------
# [6] Scripts: pull key from SSOT registry + stable smoke
# -------------------------
mkdir -p scripts

cat > scripts/tenant-from-registry.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
TENANT_ID="${TENANT_ID:-tenant_demo}"
DATA_DIR="${DATA_DIR:-./data}"

node <<'NODE'
const fs = require("fs");
const path = require("path");

const tenantId = process.env.TENANT_ID || "tenant_demo";
const dataDir = path.resolve(process.env.DATA_DIR || "./data");
const reg = path.join(dataDir, "tenants", "registry.json");

if (!fs.existsSync(reg)) {
  console.error("registry_missing:", reg);
  process.exit(2);
}
const arr = JSON.parse(fs.readFileSync(reg,"utf8"));
const t = (Array.isArray(arr) ? arr : []).find(x => x.tenantId === tenantId);
if (!t) {
  console.error("tenant_missing:", tenantId);
  process.exit(3);
}
process.stdout.write(String(t.tenantKey || "") + "\n");
NODE
BASH
chmod +x scripts/tenant-from-registry.sh
echo "✅ wrote scripts/tenant-from-registry.sh"

# Patch smoke-webhook to auto-load key from registry if missing
cat > scripts/smoke-webhook.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-}"
DATA_DIR="${DATA_DIR:-./data}"

fail(){ echo "❌ $*"; exit 1; }

if [ -z "${TENANT_KEY:-}" ]; then
  TENANT_KEY="$(TENANT_ID="$TENANT_ID" DATA_DIR="$DATA_DIR" ./scripts/tenant-from-registry.sh || true)"
fi
[ -n "${TENANT_KEY:-}" ] || fail "missing TENANT_KEY (and could not load from registry)."

echo "==> [0] health"
s0="$(curl -sS -D- "$BASE_URL/health" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s0:-}" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] send webhook intake"
payload='{"title":"Webhook Ticket (REAL)","body":"Created via smoke-webhook","customer":{"name":"ACME Ops","email":"ops@acme.test","org":"ACME"},"meta":{"channel":"smoke"}}'
s1="$(curl -sS -D- -X POST \
  -H 'content-type: application/json' \
  -H "x-tenant-id: $TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  --data "$payload" \
  "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -o /tmp/ig_webhook.json | head -n 1 | awk '{print $2}')"

[ "${s1:-}" = "201" ] || { echo "---- body ----"; cat /tmp/ig_webhook.json || true; fail "webhook not 201 (got ${s1:-})"; }
echo "✅ webhook 201"

echo "==> [2] tickets UI should be 200"
ticketsUrl="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
s2="$(curl -sS -D- "$ticketsUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s2:-}" = "200" ] || fail "tickets ui not 200: $ticketsUrl"
echo "✅ tickets ui 200"

echo "==> [3] export should be 200"
exportUrl="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
s3="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s3:-}" = "200" ] || fail "export not 200: $exportUrl"
echo "✅ export 200"

echo
echo "✅ smoke webhook ok"
echo "$ticketsUrl"
echo "$exportUrl"
BASH
chmod +x scripts/smoke-webhook.sh
echo "✅ wrote scripts/smoke-webhook.sh"

# Keep your existing smoke-ui.sh if it already works; but ensure it’s present
if [ ! -f scripts/smoke-ui.sh ]; then
  cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"
fail(){ echo "FAIL: $*"; exit 1; }

echo "==> [0] health"
s0="$(curl -sS -D- "$BASE_URL/health" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s0:-}" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -D- "$BASE_URL/ui" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui not hidden (expected 404)"

echo "==> [2] /ui/admin redirect (302 expected)"
[ -n "${ADMIN_KEY:-}" ] || fail "missing ADMIN_KEY"
hdrs="$(mktemp)"
curl -sS -D "$hdrs" -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" || true
s2="$(head -n 1 "$hdrs" | awk '{print $2}')"
echo "status=$s2"
[ "${s2:-}" = "302" ] || { echo "---- headers ----"; cat "$hdrs"; fail "expected 302"; }

loc="$(awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r/,""); print $2; exit}' "$hdrs")"
[ -n "${loc:-}" ] || { echo "---- headers ----"; cat "$hdrs"; fail "no Location header"; }
final="$BASE_URL$loc"

echo "==> [3] tickets should be 200"
s3="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s3"
[ "${s3:-}" = "200" ] || fail "tickets not 200: $final"

echo "==> [4] export should be 200"
exportUrl="$(echo "$final" | sed 's#/ui/tickets#/ui/export.csv#')"
s4="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s4"
[ "${s4:-}" = "200" ] || fail "export not 200: $exportUrl"

echo "✅ smoke ui ok"
echo "$final"
echo "$exportUrl"
BASH
  chmod +x scripts/smoke-ui.sh
  echo "✅ wrote scripts/smoke-ui.sh"
fi

# -------------------------
# [7] Typecheck (best effort)
# -------------------------
if pnpm -s lint:types >/dev/null 2>&1; then
  echo "==> Typecheck"
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase25d installed."
echo "Now:"
echo "  1) (restart) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  3) BASE_URL=http://127.0.0.1:7090 TENANT_ID=tenant_demo ./scripts/smoke-webhook.sh"
