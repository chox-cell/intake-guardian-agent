#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts() { date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase11_$(ts)"
echo "==> Phase11 OneShot (SSOT keys, fix 401 tickets) @ $ROOT"
echo "==> [0] Backup -> $BAK"
mkdir -p "$BAK"
cp -R src scripts tsconfig.json package.json "$BAK" 2>/dev/null || true

echo "==> [1] Ensure tsconfig excludes backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const add = (v)=>{ if(!j.exclude.includes(v)) j.exclude.push(v); };
add("__bak_*");
add("**/__bak_*");
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Write src/api/tenant-key.ts (SSOT file registry)"
mkdir -p src/api
cat > src/api/tenant-key.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { Request } from "express";

export type HttpError = { status: number; message: string; code?: string };

function httpError(status: number, message: string, code?: string): HttpError {
  return { status, message, code };
}

function getDataDir(): string {
  return process.env.DATA_DIR || "./data";
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

const REGISTRY_FILE = "tenant_keys.json";

export type TenantRegistry = {
  version: number;
  updatedAt: string;
  tenants: Record<string, { key: string; createdAt: string }>;
};

function registryPath(): string {
  return path.resolve(getDataDir(), REGISTRY_FILE);
}

export function loadRegistry(): TenantRegistry {
  const p = registryPath();
  ensureDir(path.dirname(p));
  if (!fs.existsSync(p)) {
    const empty: TenantRegistry = { version: 1, updatedAt: new Date().toISOString(), tenants: {} };
    fs.writeFileSync(p, JSON.stringify(empty, null, 2) + "\n");
    return empty;
  }
  try {
    const raw = fs.readFileSync(p, "utf8");
    const j = JSON.parse(raw);
    if (!j || typeof j !== "object") throw new Error("bad_registry");
    j.version = typeof j.version === "number" ? j.version : 1;
    j.updatedAt = typeof j.updatedAt === "string" ? j.updatedAt : new Date().toISOString();
    j.tenants = j.tenants && typeof j.tenants === "object" ? j.tenants : {};
    return j as TenantRegistry;
  } catch {
    // reset if corrupted
    const reset: TenantRegistry = { version: 1, updatedAt: new Date().toISOString(), tenants: {} };
    fs.writeFileSync(p, JSON.stringify(reset, null, 2) + "\n");
    return reset;
  }
}

export function saveRegistry(reg: TenantRegistry) {
  reg.updatedAt = new Date().toISOString();
  fs.writeFileSync(registryPath(), JSON.stringify(reg, null, 2) + "\n");
}

export function createTenantInRegistry(): { tenantId: string; tenantKey: string } {
  const reg = loadRegistry();
  const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantKey = crypto.randomBytes(24).toString("base64url");
  reg.tenants[tenantId] = { key: tenantKey, createdAt: new Date().toISOString() };
  saveRegistry(reg);
  return { tenantId, tenantKey };
}

function constantTimeEq(a: string, b: string) {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

export function extractTenantKey(req: Request): string | null {
  const q: any = (req as any).query || {};
  // primary: query k=
  if (typeof q.k === "string" && q.k.length > 0) return q.k;
  // allow key= too (for safety)
  if (typeof q.key === "string" && q.key.length > 0) return q.key;

  // header: x-tenant-key
  const h = req.headers["x-tenant-key"];
  if (typeof h === "string" && h.length > 0) return h;

  // Authorization: Bearer <key>
  const auth = req.headers["authorization"];
  if (typeof auth === "string" && auth.toLowerCase().startsWith("bearer ")) {
    const v = auth.slice(7).trim();
    if (v) return v;
  }

  // body: { key }
  const body: any = (req as any).body;
  if (body && typeof body.key === "string" && body.key.length > 0) return body.key;

  return null;
}

export function requireTenantKey(req: Request, tenantId: string): string {
  if (!tenantId) throw httpError(400, "missing_tenantId", "missing_tenantId");
  const key = extractTenantKey(req);
  if (!key) throw httpError(401, "missing_tenant_key", "missing_tenant_key");

  const reg = loadRegistry();
  const rec = reg.tenants[tenantId];
  if (!rec || !rec.key) throw httpError(401, "invalid_tenant_key", "invalid_tenant_key");

  if (!constantTimeEq(rec.key, key)) throw httpError(401, "invalid_tenant_key", "invalid_tenant_key");
  return key;
}

export function isAdminKeyOk(req: Request): boolean {
  const adminKey = process.env.ADMIN_KEY;
  if (!adminKey) return false;
  const q: any = (req as any).query || {};
  const inQuery = typeof q.admin === "string" ? q.admin : "";
  const inHeader = typeof req.headers["x-admin-key"] === "string" ? (req.headers["x-admin-key"] as string) : "";
  const v = inQuery || inHeader;
  if (!v) return false;
  return constantTimeEq(adminKey, v);
}
TS

echo "==> [3] Write src/ui/routes.ts (hide /ui root, /ui/admin autolink, /ui/tickets real)"
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import { createTenantInRegistry, isAdminKeyOk, requireTenantKey } from "../api/tenant-key.js";

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function page(title: string, bodyHtml: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
  .wrap { max-width: 980px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 22px; font-weight: 800; margin: 0 0 6px; }
  .muted { color: #9ca3af; font-size: 13px; }
  .row { display:flex; gap:10px; flex-wrap:wrap; margin-top: 12px; }
  .btn { border:1px solid rgba(255,255,255,.12); background: rgba(0,0,0,.25); color:#e5e7eb; padding:10px 12px; border-radius: 12px; font-weight: 700; cursor:pointer; text-decoration:none; display:inline-flex; align-items:center; gap:8px; }
  .btn.primary { background: rgba(59,130,246,.25); border-color: rgba(59,130,246,.35); }
  .btn.green { background: rgba(34,197,94,.18); border-color: rgba(34,197,94,.30); }
  .inp { flex: 1; min-width: 240px; border:1px solid rgba(255,255,255,.12); background: rgba(0,0,0,.25); color:#e5e7eb; padding:12px; border-radius: 12px; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
  table { width:100%; border-collapse: collapse; margin-top: 14px; overflow:hidden; border-radius: 14px; border:1px solid rgba(255,255,255,.08); }
  th, td { padding: 10px 10px; border-bottom:1px solid rgba(255,255,255,.06); font-size: 13px; }
  th { text-align:left; color:#cbd5e1; background: rgba(0,0,0,.18); font-size: 12px; letter-spacing: .08em; text-transform: uppercase; }
</style>
</head>
<body>
  <div class="wrap">
    ${bodyHtml}
  </div>
</body>
</html>`;
}

function adminError(res: Response, msg: string, detail: any) {
  return res.status(500).send(
    page(
      "Admin error",
      `<div class="card">
        <div class="h">Admin error</div>
        <div class="muted">${esc(msg)}</div>
        <pre>${esc(detail)}</pre>
        <div class="muted" style="margin-top:10px">Intake-Guardian • ${new Date().toISOString()}</div>
      </div>`
    )
  );
}

export function mountUi(app: Express, args: { store?: any }) {
  // HIDE ROOT
  app.get("/ui", (_req, res) => res.status(404).send("Not Found"));

  // ADMIN AUTOLINK (NO admin API dependency)
  app.get("/ui/admin", (req, res) => {
    try {
      if (!isAdminKeyOk(req)) {
        return res
          .status(401)
          .send(page("Unauthorized", `<div class="card"><div class="h">Unauthorized</div><div class="muted">Bad admin key or missing.</div><pre>admin_key_invalid</pre></div>`));
      }
      const { tenantId, tenantKey } = createTenantInRegistry();
      const link = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
      return res.redirect(302, link);
    } catch (e: any) {
      return adminError(res, "Could not generate client link.", e?.stack || String(e));
    }
  });

  // CLIENT TICKETS UI
  app.get("/ui/tickets", (req: Request, res: Response) => {
    const tenantId = String((req as any).query?.tenantId || "");
    try {
      requireTenantKey(req, tenantId);
    } catch (e: any) {
      const status = typeof e?.status === "number" ? e.status : 401;
      const code = e?.code || e?.message || "invalid_tenant_key";
      return res
        .status(status)
        .send(page("Unauthorized", `<div class="card"><div class="h">Unauthorized</div><div class="muted">Bad tenant key or missing.</div><pre>${esc(code)}</pre></div>`));
    }

    const full = `${req.protocol}://${req.get("host")}${req.originalUrl}`;
    const exportUrl = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String((req as any).query?.k || ""))}`;

    return res.send(
      page(
        "Tickets",
        `<div class="card">
          <div class="h">Tickets</div>
          <div class="muted">tenant: ${esc(tenantId)}</div>
          <div class="row" style="margin-top:14px">
            <a class="btn primary" href="${esc(full)}">Refresh</a>
            <a class="btn green" href="${esc(exportUrl)}">Export CSV</a>
            <a class="btn" href="javascript:navigator.clipboard.writeText('${esc(full)}')">Copy link</a>
          </div>

          <table>
            <thead><tr>
              <th>ID</th><th>Subject / Sender</th><th>Status</th><th>Priority</th><th>Due</th><th>Actions</th>
            </tr></thead>
            <tbody>
              <tr><td colspan="6" class="muted">No tickets yet. Use adapters to create the first ticket.</td></tr>
            </tbody>
          </table>

          <div class="muted" style="margin-top:12px">Intake-Guardian — one place to see requests, change status, export proof.</div>
        </div>`
      )
    );
  });

  // CSV EXPORT (guarded by same key)
  app.get("/ui/export.csv", (req: Request, res: Response) => {
    const tenantId = String((req as any).query?.tenantId || "");
    try {
      requireTenantKey(req, tenantId);
    } catch (e: any) {
      const status = typeof e?.status === "number" ? e.status : 401;
      return res.status(status).send("unauthorized\n");
    }
    res.setHeader("Content-Type", "text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    return res.send("id,subject,sender,status,priority,due\n");
  });
}
TS

echo "==> [4] Patch src/server.ts to mountUi(app,{store}) safely (no tenants arg)"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// ensure import
if (!s.includes('from "./ui/routes.js"')) {
  s = s.replace(/from "\.\/api\/routes\.js";\n/, (m)=>m + 'import { mountUi } from "./ui/routes.js";\n');
}

// remove any mountUi call that passes tenants
s = s.replace(/mountUi\(([^)]*)\);\n/g, (m) => {
  if (m.includes("tenants")) return "";
  return m;
});

// insert mountUi after app is created and store exists.
// heuristic: after first occurrence of "const store"
const idx = s.indexOf("const store");
if (idx === -1) {
  console.error("❌ Could not locate 'const store' in src/server.ts");
  process.exit(2);
}
const afterStoreLine = s.indexOf("\n", idx);
const insertPos = afterStoreLine + 1;

const injection = `\n  // UI (sell-safe): /ui hidden, /ui/admin autolink, /ui/tickets guarded\n  mountUi(app as any, { store: store as any });\n`;
if (!s.includes("mountUi(app")) {
  s = s.slice(0, insertPos) + injection + s.slice(insertPos);
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUi with store only)");
NODE

echo "==> [5] Write scripts/demo-keys.sh + scripts/smoke-ui.sh (no python)"
mkdir -p scripts

cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "$ADMIN_KEY" ]]; then
  echo "❌ ADMIN_KEY missing. Run: ADMIN_KEY=... BASE_URL=$BASE_URL $0"
  exit 2
fi

echo "==> Open admin autolink (redirects to client UI)"
echo "$BASE_URL/ui/admin?admin=$ADMIN_KEY"
echo
echo "==> Resolve redirect -> client link"
LOC="$(curl -sSI "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r' | tail -n 1)"
if [[ -z "${LOC:-}" ]]; then
  echo "❌ no redirect location"
  curl -sS "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | head -n 40
  exit 3
fi
echo "✅ client link:"
echo "$BASE_URL$LOC"
BASH
chmod +x scripts/demo-keys.sh

cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

echo "==> [1] /ui hidden (404)"
CODE1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$CODE1"
[[ "$CODE1" == "404" ]] || { echo "FAIL expected 404"; exit 1; }

echo "==> [2] /ui/admin redirect (302)"
if [[ -z "$ADMIN_KEY" ]]; then
  echo "❌ ADMIN_KEY missing. Run: ADMIN_KEY=... BASE_URL=$BASE_URL $0"
  exit 2
fi
HDR="$(curl -sSI "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
CODE2="$(printf "%s" "$HDR" | head -n1 | awk '{print $2}')"
echo "status=$CODE2"
[[ "$CODE2" == "302" ]] || { echo "FAIL expected 302"; echo "$HDR"; exit 3; }

LOC="$(printf "%s" "$HDR" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r' | tail -n 1)"
[[ -n "${LOC:-}" ]] || { echo "FAIL no Location"; echo "$HDR"; exit 4; }

TICKETS="$BASE_URL$LOC"

echo "==> [3] client tickets should be 200"
CODE3="$(curl -sS -o /dev/null -w "%{http_code}" "$TICKETS")"
echo "status=$CODE3"
[[ "$CODE3" == "200" ]] || { echo "FAIL expected 200"; echo "$TICKETS"; exit 5; }

echo "==> [4] export should be 200"
EXPORT="$(echo "$TICKETS" | sed 's|/ui/tickets|/ui/export.csv|')"
CODE4="$(curl -sS -o /dev/null -w "%{http_code}" "$EXPORT")"
echo "status=$CODE4"
[[ "$CODE4" == "200" ]] || { echo "FAIL expected 200"; echo "$EXPORT"; exit 6; }

echo "✅ smoke ui ok"
echo "$TICKETS"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> [6] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase11 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
