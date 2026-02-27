#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase18_${TS}"
echo "==> Phase18 OneShot (Admin API + Tenants lifecycle + Release pack) @ ${ROOT}"

echo "==> [0] Backup -> ${BAK}"
mkdir -p "${BAK}"
cp -R src scripts package.json tsconfig.json "${BAK}/" 2>/dev/null || true

echo "==> [1] Ensure tsconfig excludes backups"
node <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
if (!fs.existsSync(p)) process.exit(0);
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "dist", "node_modules"]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Write SSOT registry: src/lib/tenant_registry.ts"
mkdir -p src/lib
cat > src/lib/tenant_registry.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TenantRecord = {
  tenantId: string;
  tenantKey: string;
  createdAt: string;
  updatedAt: string;
  notes?: string;
};

export type TenantRegistry = {
  version: 1;
  updatedAt: string;
  tenants: Record<string, TenantRecord>;
  // optional stable demo tenant for /ui/admin autolink
  demo?: { tenantId: string };
};

function nowIso() {
  return new Date().toISOString();
}

function safeJsonParse<T>(s: string, fallback: T): T {
  try { return JSON.parse(s) as T; } catch { return fallback; }
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function registryPath(dataDir = "./data") {
  return path.resolve(dataDir, "tenant_registry.json");
}

export function loadRegistry(dataDir = "./data"): TenantRegistry {
  const p = registryPath(dataDir);
  ensureDir(path.dirname(p));
  if (!fs.existsSync(p)) {
    const empty: TenantRegistry = { version: 1, updatedAt: nowIso(), tenants: {} };
    fs.writeFileSync(p, JSON.stringify(empty, null, 2) + "\n");
    return empty;
  }
  const raw = fs.readFileSync(p, "utf8");
  const reg = safeJsonParse<TenantRegistry>(raw, { version: 1, updatedAt: nowIso(), tenants: {} });
  if (!reg.tenants) reg.tenants = {};
  if (!reg.version) reg.version = 1;
  return reg;
}

export function saveRegistry(dataDir: string, reg: TenantRegistry) {
  reg.updatedAt = nowIso();
  const p = registryPath(dataDir);
  ensureDir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify(reg, null, 2) + "\n");
}

export function newTenantId() {
  return `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}

export function newTenantKey() {
  // url-safe
  return crypto.randomBytes(24).toString("base64url");
}

export function upsertTenant(dataDir: string, rec: TenantRecord) {
  const reg = loadRegistry(dataDir);
  reg.tenants[rec.tenantId] = rec;
  saveRegistry(dataDir, reg);
  return rec;
}

export function createTenant(dataDir: string, notes?: string) {
  const tenantId = newTenantId();
  const tenantKey = newTenantKey();
  const t: TenantRecord = {
    tenantId,
    tenantKey,
    createdAt: nowIso(),
    updatedAt: nowIso(),
    notes,
  };
  return upsertTenant(dataDir, t);
}

export function rotateTenantKey(dataDir: string, tenantId: string) {
  const reg = loadRegistry(dataDir);
  const existing = reg.tenants[tenantId];
  if (!existing) return null;
  const next: TenantRecord = {
    ...existing,
    tenantKey: newTenantKey(),
    updatedAt: nowIso(),
  };
  reg.tenants[tenantId] = next;
  saveRegistry(dataDir, reg);
  return next;
}

export function listTenants(dataDir: string) {
  const reg = loadRegistry(dataDir);
  return Object.values(reg.tenants).sort((a,b) => (a.createdAt < b.createdAt ? 1 : -1));
}

export function getTenant(dataDir: string, tenantId: string) {
  const reg = loadRegistry(dataDir);
  return reg.tenants[tenantId] || null;
}

/**
 * verifyTenantKeyLocal compat:
 * - verifyTenantKeyLocal("tenantId", "key")  => boolean
 * - verifyTenantKeyLocal({tenantId, k})      => boolean
 */
export function verifyTenantKeyLocal(arg1: any, arg2?: any): boolean {
  const dataDir = process.env.DATA_DIR || "./data";
  let tenantId: string | undefined;
  let k: string | undefined;

  if (typeof arg1 === "string") {
    tenantId = arg1;
    k = typeof arg2 === "string" ? arg2 : undefined;
  } else if (arg1 && typeof arg1 === "object") {
    tenantId = String(arg1.tenantId || "");
    k = String(arg1.k || arg1.tenantKey || "");
  }

  if (!tenantId || !k) return false;
  const t = getTenant(dataDir, tenantId);
  if (!t) return false;
  return t.tenantKey === k;
}

export function ensureDemoTenant(dataDir: string) {
  const reg = loadRegistry(dataDir);
  if (reg.demo?.tenantId && reg.tenants[reg.demo.tenantId]) {
    return reg.tenants[reg.demo.tenantId];
  }
  const created = createTenant(dataDir, "demo (auto)");
  reg.demo = { tenantId: created.tenantId };
  reg.tenants[created.tenantId] = created;
  saveRegistry(dataDir, reg);
  return created;
}
TS

echo "==> [3] Write Admin API: src/api/admin.ts"
mkdir -p src/api
cat > src/api/admin.ts <<'TS'
import type { Express, Request } from "express";
import { createTenant, listTenants, rotateTenantKey, getTenant } from "../lib/tenant_registry.js";

function adminKeyFromReq(req: Request) {
  const q = req.query?.admin;
  const h = req.header("x-admin-key");
  const a = req.header("authorization");
  const bearer = a?.startsWith("Bearer ") ? a.slice(7) : undefined;
  return (typeof q === "string" ? q : undefined) || h || bearer || "";
}

function requireAdmin(req: Request) {
  const expected = process.env.ADMIN_KEY || "";
  if (!expected) return { ok: false as const, code: 500, error: "admin_key_not_configured" };
  const got = adminKeyFromReq(req);
  if (!got || got !== expected) return { ok: false as const, code: 401, error: "bad_admin_key" };
  return { ok: true as const };
}

export function mountAdminApi(app: Express) {
  // list tenants (no keys unless explicit)
  app.get("/api/admin/tenants", (req, res) => {
    const a = requireAdmin(req);
    if (!a.ok) return res.status(a.code).json(a);
    const tenants = listTenants(process.env.DATA_DIR || "./data").map(t => ({
      tenantId: t.tenantId,
      createdAt: t.createdAt,
      updatedAt: t.updatedAt,
      notes: t.notes || "",
    }));
    return res.json({ ok: true, tenants });
  });

  // get tenant (returns key ONLY for admin)
  app.get("/api/admin/tenants/:tenantId", (req, res) => {
    const a = requireAdmin(req);
    if (!a.ok) return res.status(a.code).json(a);
    const tenantId = String(req.params.tenantId || "");
    const t = getTenant(process.env.DATA_DIR || "./data", tenantId);
    if (!t) return res.status(404).json({ ok: false, error: "tenant_not_found" });
    return res.json({ ok: true, tenant: t });
  });

  // create tenant (returns tenantId + tenantKey)
  app.post("/api/admin/tenants/create", (req, res) => {
    const a = requireAdmin(req);
    if (!a.ok) return res.status(a.code).json(a);
    const notes = (req.body && typeof req.body.notes === "string") ? req.body.notes : "admin_create";
    const t = createTenant(process.env.DATA_DIR || "./data", notes);
    return res.json({ ok: true, tenantId: t.tenantId, tenantKey: t.tenantKey });
  });

  // rotate tenant key (returns new tenantKey)
  app.post("/api/admin/tenants/rotate", (req, res) => {
    const a = requireAdmin(req);
    if (!a.ok) return res.status(a.code).json(a);
    const tenantId =
      (req.body && typeof req.body.tenantId === "string" ? req.body.tenantId : "") ||
      (typeof req.query.tenantId === "string" ? req.query.tenantId : "");
    if (!tenantId) return res.status(400).json({ ok: false, error: "tenantId_required" });
    const next = rotateTenantKey(process.env.DATA_DIR || "./data", tenantId);
    if (!next) return res.status(404).json({ ok: false, error: "tenant_not_found" });
    return res.json({ ok: true, tenantId: next.tenantId, tenantKey: next.tenantKey });
  });
}
TS

echo "==> [4] Patch tenant key gate: src/api/tenant-key.ts (2-4 args compat + SSOT)"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";
import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";

export class HttpError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message?: string) {
    super(message || code);
    this.status = status;
    this.code = code;
  }
}

function extractTenantKey(req: Request): string {
  // priority: query k -> header -> body
  const q = req.query?.k;
  if (typeof q === "string" && q) return q;

  const h = req.header("x-tenant-key") || req.header("x-tenant") || "";
  if (h) return h;

  const a = req.header("authorization") || "";
  if (a.startsWith("Bearer ")) return a.slice(7);

  const b: any = (req as any).body;
  if (b && typeof b.k === "string") return b.k;
  if (b && typeof b.tenantKey === "string") return b.tenantKey;

  return "";
}

/**
 * Backward-compatible requireTenantKey:
 * - requireTenantKey(req, tenantId)
 * - requireTenantKey(req, tenantId, tenants, shares)  (ignored)
 * - requireTenantKey(req, tenantId, tenants)
 * returns tenantKey string or throws HttpError
 */
export function requireTenantKey(req: Request, tenantId: string, _tenants?: any, _shares?: any): string {
  const k = extractTenantKey(req);
  if (!k) throw new HttpError(401, "missing_tenant_key", "Missing tenant key");
  const ok = verifyTenantKeyLocal(tenantId, k);
  if (!ok) throw new HttpError(401, "invalid_tenant_key", "Bad tenant key");
  return k;
}
TS

echo "==> [5] Write UI routes: src/ui/routes.ts (stable /ui/admin + /ui/tickets + /ui/export.csv)"
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import type { Express, Request } from "express";
import { ensureDemoTenant } from "../lib/tenant_registry.js";
import { requireTenantKey, HttpError } from "../api/tenant-key.js";

type Ticket = {
  id: string;
  subject: string;
  sender: string;
  status: "open" | "closed";
  priority: "low" | "medium" | "high";
  due?: string;
  createdAt: string;
};

function htmlPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${title}</title>
<style>
:root { color-scheme: dark; }
body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
.wrap { max-width: 1120px; margin: 56px auto; padding: 0 18px; }
.card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
.h { font-size: 22px; font-weight: 800; margin: 0 0 6px; }
.muted { color: #9ca3af; font-size: 13px; }
.row { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin: 12px 0 14px; }
.btn { display:inline-flex; align-items:center; gap:8px; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.09); background: rgba(2,6,23,.4); color:#e5e7eb; text-decoration:none; font-weight:700; font-size: 13px; cursor:pointer; }
.btn:hover { border-color: rgba(255,255,255,.14); }
.btn.primary { background: rgba(16,185,129,.18); border-color: rgba(16,185,129,.25); }
.table { width:100%; border-collapse: collapse; margin-top: 10px; font-size: 13px; }
th, td { padding: 10px 10px; border-bottom: 1px solid rgba(255,255,255,.08); text-align:left; vertical-align:top; }
th { color:#9ca3af; font-weight:800; letter-spacing:.06em; font-size: 11px; text-transform: uppercase; }
code, pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head><body>
<div class="wrap">
  <div class="card">
    ${body}
    <div class="muted" style="margin-top:12px">Intake-Guardian • ${new Date().toISOString()}</div>
  </div>
</div>
</body></html>`;
}

function adminKeyOk(req: Request) {
  const expected = process.env.ADMIN_KEY || "";
  if (!expected) return false;
  const q = (typeof req.query?.admin === "string") ? req.query.admin : "";
  const h = req.header("x-admin-key") || "";
  const a = req.header("authorization") || "";
  const bearer = a.startsWith("Bearer ") ? a.slice(7) : "";
  const got = q || h || bearer;
  return got && got === expected;
}

// minimal store hook: try to read tickets via existing JSON store if present in app.locals
function getTicketsFromLocals(req: any, tenantId: string): Ticket[] {
  const store = req.app?.locals?.store;
  if (!store) return [];
  // best effort: support common shapes without breaking
  if (typeof store.listTickets === "function") return store.listTickets(tenantId) || [];
  if (typeof store.list === "function") return store.list(tenantId) || [];
  if (typeof store.getTickets === "function") return store.getTickets(tenantId) || [];
  return [];
}

function createDemoTicket(req: any, tenantId: string): Ticket | null {
  const store = req.app?.locals?.store;
  const t: Ticket = {
    id: `t_${Date.now()}_${Math.random().toString(16).slice(2,10)}`,
    subject: "New request: Onboarding question",
    sender: "client@example.com",
    status: "open",
    priority: "medium",
    createdAt: new Date().toISOString(),
  };
  if (!store) return t;

  if (typeof store.createTicket === "function") { store.createTicket(tenantId, t); return t; }
  if (typeof store.create === "function") { store.create(tenantId, t); return t; }
  if (typeof store.addTicket === "function") { store.addTicket(tenantId, t); return t; }

  return t;
}

function csvEscape(s: any) {
  const v = String(s ?? "");
  if (v.includes(",") || v.includes('"') || v.includes("\n")) return `"${v.replace(/"/g,'""')}"`;
  return v;
}

export function mountUi(app: Express) {
  // hide /ui root
  app.get("/ui", (_req, res) => res.status(404).send("Not Found"));

  // stable autolink: no admin API dependency, just creates/ensures demo tenant
  app.get("/ui/admin", (req, res) => {
    try {
      if (!adminKeyOk(req)) {
        const body = `<div class="h">Admin error</div><div class="muted">bad_admin_key</div>`;
        return res.status(401).send(htmlPage("Admin error", body));
      }
      const t = ensureDemoTenant(process.env.DATA_DIR || "./data");
      const url = `/ui/tickets?tenantId=${encodeURIComponent(t.tenantId)}&k=${encodeURIComponent(t.tenantKey)}`;
      return res.redirect(302, url);
    } catch (err: any) {
      const body = `<div class="h">Admin error</div><div class="muted">autolink_failed</div><pre>${String(err?.stack || err)}</pre>`;
      return res.status(500).send(htmlPage("Admin error", body));
    }
  });

  // tickets UI
  app.get("/ui/tickets", (req, res) => {
    try {
      const tenantId = (typeof req.query?.tenantId === "string") ? req.query.tenantId : "";
      if (!tenantId) throw new HttpError(400, "missing_tenantId", "tenantId required");
      requireTenantKey(req, tenantId);

      const tickets = getTicketsFromLocals(req, tenantId);
      const rows = tickets.length ? tickets.map(t => `
        <tr>
          <td>${t.id}</td>
          <td><div style="font-weight:800">${t.subject}</div><div class="muted">${t.sender}</div></td>
          <td>${t.status}</td>
          <td>${t.priority}</td>
          <td>${t.due || ""}</td>
          <td>${t.createdAt || ""}</td>
        </tr>
      `).join("") : `<tr><td colspan="6" class="muted">No tickets yet. Use adapters to create the first ticket.</td></tr>`;

      const exportUrl = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent((req.query as any).k || "")}`;
      const copyLink = `${req.protocol}://${req.get("host")}${req.originalUrl}`;
      const body = `
        <div class="h">Tickets</div>
        <div class="muted">tenant: <code>${tenantId}</code></div>
        <div class="row">
          <a class="btn" href="${req.originalUrl}">Refresh</a>
          <a class="btn primary" href="${exportUrl}">Export CSV</a>
          <form method="post" action="/ui/demo-ticket" style="display:inline">
            <input type="hidden" name="tenantId" value="${tenantId}" />
            <input type="hidden" name="k" value="${String((req.query as any).k || "")}" />
            <button class="btn" type="submit">Create demo ticket</button>
          </form>
          <button class="btn" onclick="navigator.clipboard.writeText('${copyLink.replace(/'/g,"\\'")}')">Copy link</button>
        </div>
        <table class="table">
          <thead><tr>
            <th>ID</th><th>SUBJECT / SENDER</th><th>STATUS</th><th>PRIORITY</th><th>DUE</th><th>CREATED</th>
          </tr></thead>
          <tbody>${rows}</tbody>
        </table>
        <div class="muted">Intake-Guardian — one place to see requests, change status, export proof.</div>
      `;
      return res.status(200).send(htmlPage("Tickets", body));
    } catch (err: any) {
      const status = err?.status || 401;
      const code = err?.code || "unauthorized";
      const body = `<div class="h">Unauthorized</div><div class="muted">Bad tenant key or missing.</div><pre>${code}</pre>`;
      return res.status(status).send(htmlPage("Unauthorized", body));
    }
  });

  // create demo ticket
  app.post("/ui/demo-ticket", (req: any, res) => {
    try {
      const tenantId = String(req.body?.tenantId || "");
      const k = String(req.body?.k || "");
      if (!tenantId) throw new HttpError(400, "missing_tenantId");
      // allow form post keys via body
      (req.query as any).k = k;
      requireTenantKey(req, tenantId);
      createDemoTicket(req, tenantId);
      return res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
    } catch (err: any) {
      const body = `<div class="h">Error</div><div class="muted">demo_ticket_failed</div><pre>${String(err?.stack || err)}</pre>`;
      return res.status(500).send(htmlPage("Error", body));
    }
  });

  // export CSV
  app.get("/ui/export.csv", (req, res) => {
    try {
      const tenantId = (typeof req.query?.tenantId === "string") ? req.query.tenantId : "";
      if (!tenantId) throw new HttpError(400, "missing_tenantId");
      requireTenantKey(req, tenantId);
      const tickets = getTicketsFromLocals(req as any, tenantId);

      const header = ["id","subject","sender","status","priority","due","createdAt"].join(",");
      const lines = tickets.map(t => [
        csvEscape(t.id),
        csvEscape(t.subject),
        csvEscape(t.sender),
        csvEscape(t.status),
        csvEscape(t.priority),
        csvEscape(t.due || ""),
        csvEscape(t.createdAt || "")
      ].join(","));
      const csv = [header, ...lines].join("\n") + "\n";
      res.setHeader("content-type", "text/csv; charset=utf-8");
      return res.status(200).send(csv);
    } catch (err: any) {
      const status = err?.status || 401;
      const code = err?.code || "unauthorized";
      return res.status(status).send(code);
    }
  });
}
TS

echo "==> [6] Patch server.ts to mount UI + Admin API safely (and set app.locals.store)"
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
if (!fs.existsSync(p)) throw new Error("src/server.ts not found");

let s = fs.readFileSync(p,"utf8");

// ensure imports
if (!s.includes('from "./ui/routes.js"') && !s.includes('from "./ui/routes.ts"')) {
  s = s.replace(/(import .*express.*\n)/, `$1import { mountUi } from "./ui/routes.js";\n`);
}
if (!s.includes('from "./api/admin.js"')) {
  s = s.replace(/(import .*express.*\n)/, `$1import { mountAdminApi } from "./api/admin.js";\n`);
}

// ensure mountAdminApi + mountUi called after app created
if (!s.includes("mountAdminApi(")) {
  s = s.replace(/(const app\s*=\s*express\(\)\s*;)/, `$1\n  mountAdminApi(app as any);\n`);
}

// make sure body parsers exist (best effort)
if (!s.includes("express.json")) {
  s = s.replace(/(const app\s*=\s*express\(\)\s*;)/, `$1\n  app.use(express.json({ limit: "1mb" }));\n  app.use(express.urlencoded({ extended: true }));\n`);
}

// ensure UI mounted
if (!s.match(/mountUi\(/)) {
  s = s.replace(/(app\.use\(\s*["']\/api["']\s*,\s*makeRoutes\([^;]*;)/, `$1\n  mountUi(app as any);\n`);
} else {
  // normalize call signature to mountUi(app)
  s = s.replace(/mountUi\(\s*app[^)]*\)\s*;/g, "mountUi(app as any);");
}

// ensure app.locals.store set if store variable exists
if (!s.includes("app.locals.store")) {
  // try inject after store constructed
  s = s.replace(/(const store\s*=\s*new [A-Za-z0-9_]+\(.*\)\s*;)/, `$1\n  (app as any).locals = (app as any).locals || {};\n  (app as any).locals.store = store as any;\n`);
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountAdminApi + mountUi + locals.store)");
NODE

echo "==> [7] Rewrite scripts/demo-keys.sh (bash-only + stable)"
cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "${ADMIN_KEY}" ]]; then
  echo "ERR: ADMIN_KEY is required"
  exit 1
fi

echo "==> Open admin autolink (stable demo tenant)"
ADMIN_URL="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
echo "${ADMIN_URL}"
echo

echo "==> Resolve redirect -> final client link"
final="$(curl -sS -o /dev/null -w '%{redirect_url}' -L "${ADMIN_URL}")"
if [[ -z "${final}" ]]; then
  # fallback: get Location header from 302
  final="$(curl -sS -D - "${ADMIN_URL}" -o /dev/null | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r\n')"
fi
if [[ "${final}" != http* ]]; then
  final="${BASE_URL}${final}"
fi

echo "✅ client link:"
echo "${final}"
echo
echo "==> ✅ Export CSV"
echo "${final/\/ui\/tickets/\/ui\/export.csv}"
BASH
chmod +x scripts/demo-keys.sh

echo "==> [8] Rewrite scripts/smoke-ui.sh (bash-only, stable export)"
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "==> [0] health"
curl -fsS "${BASE_URL}/health" >/dev/null && echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/ui")"
echo "status=$code"
[[ "$code" == "404" ]] || fail "expected 404"

echo "==> [2] /ui/admin redirect (302 expected)"
[[ -n "${ADMIN_KEY}" ]] || fail "ADMIN_KEY required"
admin_url="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
code="$(curl -sS -o /dev/null -w '%{http_code}' "${admin_url}")"
echo "status=$code"
[[ "$code" == "302" ]] || fail "expected 302"

echo "==> [3] follow redirect -> tickets should be 200"
final="$(curl -sS -o /dev/null -w '%{redirect_url}' -L "${admin_url}")"
[[ -n "${final}" ]] || fail "no redirect_url"
code="$(curl -sS -o /dev/null -w '%{http_code}' "${final}")"
echo "status=$code"
[[ "$code" == "200" ]] || fail "expected 200 on tickets"

echo "==> [4] export should be 200"
export_url="${final/\/ui\/tickets/\/ui\/export.csv}"
code="$(curl -sS -o /dev/null -w '%{http_code}' "${export_url}")"
echo "status=$code"
[[ "$code" == "200" ]] || fail "expected 200 on export: $export_url"

echo "✅ smoke ui ok"
echo "$final"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> [9] Release pack script: scripts/release-pack.sh"
cat > scripts/release-pack.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${OUT_DIR:-dist/intake-guardian-agent}"
mkdir -p "${OUT_DIR}"

echo "==> clean ${OUT_DIR}"
rm -rf "${OUT_DIR:?}/"* 2>/dev/null || true

echo "==> build zip (source + minimal docs)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || echo "WARN: not a git repo (ok)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")"
TS="$(date +%Y-%m-%d_%H%M)"
PKG="intake-guardian-agent_${TS}_${SHA}"

mkdir -p "${OUT_DIR}/${PKG}"
cp -R src scripts package.json tsconfig.json "${OUT_DIR}/${PKG}/" 2>/dev/null || true

cat > "${OUT_DIR}/${PKG}/RUN.md" <<EOF
# Intake-Guardian Agent — Run

## Dev
\`\`\`bash
pnpm i
ADMIN_KEY=super_secret_admin_123 pnpm dev
ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh
ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh
\`\`\`

## UI
- Admin autolink:
  \`http://127.0.0.1:7090/ui/admin?admin=ADMIN_KEY\`
EOF

( cd "${OUT_DIR}" && zip -qr "${PKG}.zip" "${PKG}" )
echo "✅ wrote: ${OUT_DIR}/${PKG}.zip"
BASH
chmod +x scripts/release-pack.sh

echo "==> [10] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase18 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo
echo "Admin API:"
echo "  curl -H 'x-admin-key: super_secret_admin_123' ${BASE_URL:-http://127.0.0.1:7090}/api/admin/tenants"
echo
echo "Release pack:"
echo "  ./scripts/release-pack.sh"
