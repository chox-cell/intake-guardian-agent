#!/usr/bin/env bash
set -euo pipefail

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase16_${ts}"
echo "==> Phase16 OneShot (SSOT tenant keys + stable UI auth + stable bash scripts)"
mkdir -p "$bak"
cp -R src scripts tsconfig.json "$bak"/ 2>/dev/null || true
echo "✅ backup -> $bak"

echo "==> [1] Write SSOT registry: src/lib/tenant_registry.ts"
mkdir -p src/lib
cat > src/lib/tenant_registry.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TenantRec = {
  tenantId: string;
  tenantKey: string;
  createdAt: string;
  note?: string;
};

const REG_PATH = path.resolve(process.cwd(), "data", "tenant_keys.json");

function ensureDir() {
  fs.mkdirSync(path.dirname(REG_PATH), { recursive: true });
}

function readAll(): Record<string, TenantRec> {
  try {
    const raw = fs.readFileSync(REG_PATH, "utf8");
    const j = JSON.parse(raw);
    if (!j || typeof j !== "object") return {};
    return j as Record<string, TenantRec>;
  } catch {
    return {};
  }
}

function writeAll(obj: Record<string, TenantRec>) {
  ensureDir();
  fs.writeFileSync(REG_PATH, JSON.stringify(obj, null, 2));
}

export function upsertTenantKey(tenantId: string, tenantKey: string, note?: string) {
  const all = readAll();
  all[tenantId] = { tenantId, tenantKey, createdAt: new Date().toISOString(), note };
  writeAll(all);
  return all[tenantId];
}

export function getTenantKey(tenantId: string): string | null {
  const all = readAll();
  return all[tenantId]?.tenantKey ?? null;
}

export function rotateTenantKey(note?: string) {
  const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantKey = crypto.randomBytes(24).toString("base64url");
  upsertTenantKey(tenantId, tenantKey, note ?? "rotated");
  return { tenantId, tenantKey };
}

export function verifyTenantKeyLocal(tenantId: string, providedKey: string): boolean {
  const expected = getTenantKey(tenantId);
  if (!expected) return false;
  const a = Buffer.from(String(expected));
  const b = Buffer.from(String(providedKey ?? ""));
  if (a.length !== b.length) return false;
  try {
    return crypto.timingSafeEqual(a, b);
  } catch {
    return String(expected) === String(providedKey ?? "");
  }
}
TS

echo "==> [2] Patch src/api/tenant-key.ts to be backward-compatible (2-4 args) and SSOT-based"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";
import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";

export class HttpError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, msg?: string) {
    super(msg ?? code);
    this.status = status;
    this.code = code;
  }
}

/**
 * Backward compatible:
 * - requireTenantKey(req, tenantId)
 * - requireTenantKey(req, tenantId, tenants)
 * - requireTenantKey(req, tenantId, tenants, shares)
 *
 * Reads key from:
 * - ?k=
 * - header: x-tenant-key
 * - body: { k, tenantKey }
 */
export function requireTenantKey(req: Request, tenantId: string, _tenants?: any, _shares?: any): string {
  const qk = (req.query?.k as string | undefined) ?? undefined;
  const hk = (req.headers["x-tenant-key"] as string | undefined) ?? undefined;

  // body can be object; keep it safe
  const bk =
    (req.body && typeof req.body === "object" && (req.body.k || req.body.tenantKey)) ? String(req.body.k || req.body.tenantKey) : undefined;

  const k = qk ?? hk ?? bk;
  if (!k) throw new HttpError(401, "missing_tenant_key", "Bad tenant key or missing.");

  const ok = verifyTenantKeyLocal(String(tenantId), String(k));
  if (!ok) throw new HttpError(401, "invalid_tenant_key", "Bad tenant key or missing.");

  return String(k);
}

export function verifyTenantKey(req: Request, tenantId: string): boolean {
  try {
    requireTenantKey(req, tenantId);
    return true;
  } catch {
    return false;
  }
}
TS

echo "==> [3] Write UI routes: src/ui/routes.ts (NO require, SSOT keys only)"
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import crypto from "node:crypto";
import { rotateTenantKey, verifyTenantKeyLocal } from "../lib/tenant_registry.js";

function constantTimeEq(a: any, b: any) {
  const aa = Buffer.from(String(a ?? ""));
  const bb = Buffer.from(String(b ?? ""));
  if (aa.length !== bb.length) return false;
  try { return crypto.timingSafeEqual(aa, bb); } catch { return String(a ?? "") === String(b ?? ""); }
}

function adminOk(req: Request): boolean {
  const admin = String(req.query?.admin ?? "");
  const expected = String(process.env.ADMIN_KEY ?? "");
  if (!expected) return false;
  return constantTimeEq(admin, expected);
}

function html(title: string, body: string) {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${title}</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial; background: radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%); color:#e5e7eb; }
  .wrap { max-width: 980px; margin: 56px auto; padding: 0 18px; }
  .card { border:1px solid rgba(255,255,255,.08); background: rgba(17,24,39,.55); border-radius: 18px; padding: 18px 18px; box-shadow: 0 18px 60px rgba(0,0,0,.35); }
  .h { font-size: 22px; font-weight: 800; margin: 0 0 6px; }
  .muted { color: #9ca3af; font-size: 13px; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
  a { color:#93c5fd; text-decoration:none; }
  .btn { display:inline-block; padding:10px 14px; border-radius:12px; border:1px solid rgba(255,255,255,.10); background: rgba(2,6,23,.45); }
</style>
</head><body>
<div class="wrap"><div class="card">
${body}
<div class="muted" style="margin-top:10px">Intake-Guardian • ${new Date().toISOString()}</div>
</div></div>
</body></html>`;
}

export function mountUi(app: Express) {
  // hide /ui root
  app.get("/ui", (_req, res) => res.status(404).send("Not found"));

  // admin autolink => generate tenantId+key and redirect
  app.get("/ui/admin", (req, res) => {
    if (!adminOk(req)) {
      res.status(401).send(html("Admin error", `<div class="h">Admin error</div><div class="muted">admin_key_not_configured_or_invalid</div>`));
      return;
    }
    const { tenantId, tenantKey } = rotateTenantKey("admin_autolink");
    const loc = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`;
    res.redirect(302, loc);
  });

  // tickets UI
  app.get("/ui/tickets", (req: Request, res: Response) => {
    const tenantId = String(req.query?.tenantId ?? "");
    const k = String(req.query?.k ?? "");
    if (!tenantId || !k || !verifyTenantKeyLocal(tenantId, k)) {
      res.status(401).send(html("Unauthorized", `<div class="h">Unauthorized</div><div class="muted">Bad tenant key or missing.</div><pre>invalid_tenant_key</pre>`));
      return;
    }

    // Minimal UI (kept consistent with your theme)
    res.status(200).send(html("Tickets", `
      <div class="h">Tickets</div>
      <div class="muted">tenant: <b>${tenantId}</b></div>
      <div style="margin-top:14px; display:flex; gap:10px; flex-wrap:wrap;">
        <a class="btn" href="/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">Refresh</a>
        <a class="btn" href="/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">Export CSV</a>
        <a class="btn" href="#" onclick="navigator.clipboard.writeText(location.href); return false;">Copy link</a>
      </div>
      <div style="margin-top:14px; border-top:1px solid rgba(255,255,255,.08); padding-top:14px" class="muted">
        No tickets yet. Use adapters to create the first ticket.
      </div>
    `));
  });

  // export CSV (basic stub but 200)
  app.get("/ui/export.csv", (req, res) => {
    const tenantId = String(req.query?.tenantId ?? "");
    const k = String(req.query?.k ?? "");
    if (!tenantId || !k || !verifyTenantKeyLocal(tenantId, k)) {
      res.status(401).setHeader("content-type", "text/plain").send("invalid_tenant_key");
      return;
    }
    res.status(200).setHeader("content-type", "text/csv; charset=utf-8");
    res.send("id,subject,sender,status,priority,due\n");
  });
}
TS

echo "==> [4] Patch server.ts to import mountUi + call it safely (store not needed)"
node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const p = path.join(process.cwd(), "src/server.ts");
let s = fs.readFileSync(p, "utf8");

// ensure import
if (!s.includes('from "./ui/routes.js"')) {
  s = s.replace(/(import\s+.*?\n)/, `$1import { mountUi } from "./ui/routes.js";\n`);
} else if (!s.includes("mountUi")) {
  // keep
}

if (!s.includes("mountUi(app")) {
  // insert after app created, before listen (best effort)
  const marker = "const app";
  const idx = s.indexOf(marker);
  if (idx !== -1) {
    // after app is declared, find end of that line
    const lineEnd = s.indexOf("\n", idx);
    const inject = "\n// UI (sell)\nmountUi(app as any);\n";
    // place after app is initialized (heuristic)
    // try after first app.use(...) if exists else after const app line
    const useIdx = s.indexOf("app.use(", lineEnd);
    if (useIdx !== -1) {
      const afterUseLine = s.indexOf("\n", useIdx);
      s = s.slice(0, afterUseLine + 1) + inject + s.slice(afterUseLine + 1);
    } else {
      s = s.slice(0, lineEnd + 1) + inject + s.slice(lineEnd + 1);
    }
  }
}

// remove any old mountUI/mountUi mismatches duplicates (light cleanup)
s = s.replace(/import\s+\{\s*mountUI\s*\}\s+from\s+"\.\/*ui\/routes\.js";\s*\n/g, "");
s = s.replace(/mountUI\(/g, "mountUi(");

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUi added)");
NODE

echo "==> [5] Rewrite scripts/demo-keys.sh + smoke-ui.sh (bash-only, correct URLs)"
cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-dev_admin_key_123}"

admin_url="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
echo "==> Open admin autolink (will redirect to client UI)"
echo "$admin_url"
echo

loc="$(
  curl -sS -I "$admin_url" \
  | tr -d '\r' \
  | awk 'tolower($1)=="location:"{print $2; exit}'
)"

if [[ -z "${loc:-}" ]]; then
  echo "❌ no redirect location from /ui/admin"
  curl -sS -i "$admin_url" | head -n 80
  exit 1
fi

if [[ "$loc" == /* ]]; then final="${BASE_URL}${loc}"; else final="$loc"; fi
echo "✅ client link:"
echo "$final"
echo
echo "==> ✅ Export CSV"
echo "${final/\/ui\/tickets/\/ui\/export.csv}"
BASH
chmod +x scripts/demo-keys.sh

cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-dev_admin_key_123}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
curl -fsS "${BASE_URL}/health" >/dev/null && echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
code="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ui" || true)"
echo "status=$code"
[[ "$code" == "404" ]] || fail "expected 404 for /ui"

echo "==> [2] /ui/admin redirect (302 expected)"
admin_url="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
code="$(curl -sS -o /dev/null -w "%{http_code}" -I "$admin_url" || true)"
echo "status=$code"
[[ "$code" == "302" ]] || {
  echo "---- headers ----"
  curl -sS -I "$admin_url" | head -n 40
  echo "---- body ----"
  curl -sS "$admin_url" | head -n 80
  fail "expected 302 from /ui/admin"
}

loc="$(curl -sS -I "$admin_url" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2; exit}')"
[[ -n "${loc:-}" ]] || fail "no Location header"

if [[ "$loc" == /* ]]; then final="${BASE_URL}${loc}"; else final="$loc"; fi

echo "==> [3] tickets should be 200"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$final" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "expected 200 on tickets: $final"

echo "==> [4] export should be 200"
export_url="${final/\/ui\/tickets/\/ui\/export.csv}"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$export_url" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "expected 200 on export: $export_url"

echo "✅ smoke ui ok"
echo "$final"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> [6] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase16 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
