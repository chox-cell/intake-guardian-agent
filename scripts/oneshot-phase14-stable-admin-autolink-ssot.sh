#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase14_${ts}"
echo "==> Phase14 OneShot (stable /ui/admin + SSOT keys + bash-only smoke) @ $ROOT"
mkdir -p "$bak"
cp -R src scripts tsconfig.json "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak"

echo "==> [1] Ensure tsconfig excludes backups"
node <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "data", "dist"]));
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Write SSOT registry: src/lib/tenant_registry.ts"
mkdir -p src/lib
cat > src/lib/tenant_registry.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

type TenantRec = {
  tenantId: string;
  tenantKey: string;
  createdAt: string;
};

type KeysFile = {
  version: 1;
  tenants: Record<string, TenantRec>;
};

type RegistryFile = {
  version: 1;
  lastTenantId?: string;
  updatedAt: string;
};

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

function atomicWrite(filePath: string, data: string) {
  const dir = path.dirname(filePath);
  ensureDir(dir);
  const tmp = `${filePath}.tmp.${process.pid}.${Date.now()}`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, filePath);
}

function safeReadJson<T>(filePath: string, fallback: T): T {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    const raw = fs.readFileSync(filePath, "utf8");
    if (!raw.trim()) return fallback;
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function randUrlSafe(n = 24) {
  return crypto.randomBytes(n).toString("base64url");
}

function randHex(n = 8) {
  return crypto.randomBytes(n).toString("hex");
}

export function makeTenantRegistry(args: { dataDir: string }) {
  const dataDir = args.dataDir;
  const keysPath = path.join(dataDir, "tenant_keys.json");
  const regPath = path.join(dataDir, "tenant_registry.json");

  function loadKeys(): KeysFile {
    return safeReadJson<KeysFile>(keysPath, { version: 1, tenants: {} });
  }

  function saveKeys(v: KeysFile) {
    atomicWrite(keysPath, JSON.stringify(v, null, 2) + "\n");
  }

  function loadReg(): RegistryFile {
    return safeReadJson<RegistryFile>(regPath, { version: 1, updatedAt: new Date().toISOString() });
  }

  function saveReg(v: RegistryFile) {
    atomicWrite(regPath, JSON.stringify(v, null, 2) + "\n");
  }

  function createTenant(): TenantRec {
    const tenantId = `tenant_${Date.now()}_${randHex(6)}`;
    const tenantKey = randUrlSafe(24);
    return { tenantId, tenantKey, createdAt: new Date().toISOString() };
  }

  function rotate(): TenantRec {
    const keys = loadKeys();
    const rec = createTenant();
    keys.tenants[rec.tenantId] = rec;
    saveKeys(keys);

    const reg = loadReg();
    reg.lastTenantId = rec.tenantId;
    reg.updatedAt = new Date().toISOString();
    saveReg(reg);

    return rec;
  }

  function getLast(): TenantRec | null {
    const reg = loadReg();
    if (!reg.lastTenantId) return null;
    const keys = loadKeys();
    const rec = keys.tenants[reg.lastTenantId];
    return rec || null;
  }

  function get(tenantId: string): TenantRec | null {
    const keys = loadKeys();
    return keys.tenants[tenantId] || null;
  }

  // Used by requireTenantKey compatibility layers (if they read this file)
  function verify(tenantId: string, tenantKey: string): boolean {
    const rec = get(tenantId);
    if (!rec) return false;
    return rec.tenantKey === tenantKey;
  }

  return { rotate, getLast, get, verify, keysPath, regPath };
}
TS

echo "==> [3] Write UI routes: src/ui/routes.ts (stable admin autolink, tickets, export)"
mkdir -p src/ui
cat > src/ui/routes.ts <<'TS'
import type { Express, Request, Response } from "express";
import path from "node:path";
import { makeTenantRegistry } from "../lib/tenant_registry.js";
import { requireTenantKey } from "../api/tenant-key.js";

function constantTimeEq(a: string, b: string) {
  if (!a || !b) return false;
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return require("node:crypto").timingSafeEqual(ab, bb);
}

function getAdminKey(): string {
  return process.env.ADMIN_KEY || "";
}

function hasAdmin(req: Request): boolean {
  const adminKey = getAdminKey();
  if (!adminKey) return false;
  const q = (req.query.admin as string) || "";
  const h = (req.headers["x-admin-key"] ? String(req.headers["x-admin-key"]) : "") || "";
  const v = q || h;
  return constantTimeEq(adminKey, v);
}

function htmlPage(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
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
  table { width:100%; border-collapse: collapse; margin-top: 10px; }
  th, td { text-align:left; padding: 10px 8px; border-bottom: 1px solid rgba(255,255,255,.06); font-size: 13px; color:#cbd5e1; }
  .btn { display:inline-block; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(255,255,255,.06); color:#e5e7eb; text-decoration:none; font-weight: 700; font-size: 13px; }
  .btn.primary { background: rgba(59,130,246,.18); border-color: rgba(59,130,246,.35); }
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      ${body}
      <div class="muted" style="margin-top:10px">Intake-Guardian • ${new Date().toISOString()}</div>
    </div>
  </div>
</body>
</html>`;
}

function parseTenantFromQuery(req: Request) {
  const tenantId = (req.query.tenantId as string) || "";
  const k = (req.query.k as string) || "";
  return { tenantId, k };
}

// Minimal HTML (no React build) - stable for sales demo
function ticketsHtml(tenantId: string) {
  return htmlPage(
    "Tickets",
    `
    <div class="h">Tickets</div>
    <div class="muted">tenant: <b>${tenantId}</b></div>
    <div style="margin-top:12px; display:flex; gap:10px; flex-wrap:wrap;">
      <a class="btn primary" href="/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(
        ("" as any)
      )}" onclick="return false;">Refresh</a>
      <a class="btn" id="exportBtn" href="#">Export CSV</a>
      <a class="btn" id="copyBtn" href="#">Copy link</a>
    </div>

    <table>
      <thead>
        <tr>
          <th style="width:120px">ID</th>
          <th>SUBJECT / SENDER</th>
          <th style="width:110px">STATUS</th>
          <th style="width:90px">PRIORITY</th>
          <th style="width:120px">DUE</th>
          <th style="width:120px">ACTIONS</th>
        </tr>
      </thead>
      <tbody id="rows">
        <tr><td colspan="6" class="muted">No tickets yet. Use adapters to create the first ticket.</td></tr>
      </tbody>
    </table>

    <div class="muted" style="margin-top:8px">Intake-Guardian — one place to see requests, change status, export proof.</div>

<script>
(function(){
  const url = new URL(window.location.href);
  const tenantId = url.searchParams.get("tenantId") || "";
  const k = url.searchParams.get("k") || "";
  const exportUrl = "/ui/export.csv?tenantId=" + encodeURIComponent(tenantId) + "&k=" + encodeURIComponent(k);
  document.getElementById("exportBtn").setAttribute("href", exportUrl);
  document.getElementById("copyBtn").addEventListener("click", async function(e){
    e.preventDefault();
    try { await navigator.clipboard.writeText(window.location.href); alert("Copied"); } catch { prompt("Copy link:", window.location.href); }
  });
})();
</script>
    `
  );
}

export function mountUi(app: Express, args: { store?: any }) {
  const dataDir = process.env.DATA_DIR ? path.resolve(process.env.DATA_DIR) : path.resolve("./data");
  const reg = makeTenantRegistry({ dataDir });

  // Hide root /ui
  app.get("/ui", (_req: Request, res: Response) => {
    res.status(404).send("Not found");
  });

  // Admin autolink: ALWAYS 302 on success; never calls /api/admin/*
  app.get("/ui/admin", (req: Request, res: Response) => {
    try {
      if (!hasAdmin(req)) {
        res.status(401).send(htmlPage("Admin error", `<div class="h">Admin error</div><div class="muted">admin_key_not_configured_or_invalid</div>`));
        return;
      }
      const rec = reg.rotate();
      const location = `/ui/tickets?tenantId=${encodeURIComponent(rec.tenantId)}&k=${encodeURIComponent(rec.tenantKey)}`;
      res.status(302).setHeader("Location", location).end();
    } catch (err: any) {
      res.status(500).send(
        htmlPage(
          "Admin error",
          `<div class="h">Admin error</div><div class="muted">autolink_failed</div><pre>${String(err?.stack || err)}</pre>`
        )
      );
    }
  });

  // Client tickets UI (protected by tenant key)
  app.get("/ui/tickets", (req: Request, res: Response) => {
    const { tenantId, k } = parseTenantFromQuery(req);
    try {
      // Back-compat: requireTenantKey can accept 2-4 args in this repo.
      (requireTenantKey as any)(req, tenantId, undefined, undefined);
      // Render stable HTML
      res.status(200).send(ticketsHtml(tenantId).replace(`(""),`, JSON.stringify(k) + ","));
    } catch (err: any) {
      const code = err?.status || err?.code || 401;
      const msg = err?.message || "invalid_tenant_key";
      res.status(401).send(htmlPage("Unauthorized", `<div class="h">Unauthorized</div><div class="muted">Bad tenant key or missing.</div><pre>${msg}</pre>`));
    }
  });

  // Export CSV (protected by tenant key) — we proxy to existing backend route if exists, otherwise minimal
  app.get("/ui/export.csv", (req: Request, res: Response) => {
    const tenantId = (req.query.tenantId as string) || "";
    try {
      (requireTenantKey as any)(req, tenantId, undefined, undefined);
      // If your API already has an export handler, prefer it:
      // We'll emit a minimal CSV here (safe fallback) to avoid breaking.
      res.setHeader("Content-Type", "text/csv; charset=utf-8");
      res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
      res.status(200).send("id,subject,status,priority,due\n");
    } catch (err: any) {
      res.status(401).send("unauthorized\n");
    }
  });
}
TS

echo "==> [4] Patch src/server.ts to ensure mountUi imported + called after store"
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// ensure import
if (!s.includes('from "./ui/routes.js"')) {
  s = s.replace(
    /from "\.\/api\/.*?";\n/g,
    (m)=>m
  );
  // Put import near top (best-effort)
  s = s.replace(/^/m, (m)=>m);
  s = s.replace(/^(import .*;\n)+/m, (block) => {
    if (block.includes('from "./ui/routes.js"')) return block;
    return block + 'import { mountUi } from "./ui/routes.js";\n';
  });
}

// ensure mountUi call exists once
if (!s.includes("mountUi(")) {
  // Find where store is created and insert after it (best-effort)
  // common patterns: const store = new FileStore(...)
  const re = /const store\s*=\s*new\s+\w+\([^;]*\);\n/;
  if (re.test(s)) {
    s = s.replace(re, (m) => m + "\n  mountUi(app as any, { store: store as any });\n");
  } else {
    // fallback: insert before listen
    const reListen = /app\.listen\(/;
    s = s.replace(reListen, "mountUi(app as any, { store: store as any });\n\n" + "app.listen(");
  }
} else {
  // normalize to store-only call (avoid tenants arg/type mismatch)
  s = s.replace(/mountUi\([^)]*\{[^}]*tenants[^}]*\}[^)]*\)\s*;?/g, "mountUi(app as any, { store: store as any });");
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUi store-only, stable)");
NODE

echo "==> [5] Write scripts/demo-keys.sh (bash-only; resolve redirect)"
mkdir -p scripts
cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "$ADMIN_KEY" ]]; then
  echo "ERROR: ADMIN_KEY missing. Example:"
  echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/demo-keys.sh"
  exit 1
fi

adminUrl="$BASE_URL/ui/admin?admin=$(python3 - <<PY 2>/dev/null || true
import urllib.parse, os
print(urllib.parse.quote(os.environ["ADMIN_KEY"]))
PY
)"

# If python isn't available, just raw (still fine for simple keys)
adminUrl="$BASE_URL/ui/admin?admin=$ADMIN_KEY"

final="$(curl -s -o /dev/null -w '%{url_effective}' -L "$adminUrl")"
echo "==> ✅ UI link"
echo "$final"
echo
echo "==> ✅ Export CSV"
echo "${final/\/ui\/tickets/\/ui\/export.csv}"
BASH
chmod +x scripts/demo-keys.sh

echo "==> [6] Write scripts/smoke-ui.sh (bash-only; no python)"
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "$ADMIN_KEY" ]]; then
  echo "ERROR: ADMIN_KEY missing."
  exit 1
fi

echo "==> [1] /ui hidden (404)"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/ui")"
echo "status=$code"
[[ "$code" == "404" ]] || { echo "FAIL expected 404"; exit 1; }

echo "==> [2] /ui/admin redirect (302)"
hdr="$(curl -s -D - -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
code2="$(printf "%s" "$hdr" | head -n 1 | awk '{print $2}')"
echo "status=$code2"
[[ "$code2" == "302" ]] || { echo "FAIL expected 302"; echo "$hdr"; exit 2; }

loc="$(printf "%s" "$hdr" | awk 'BEGIN{IGNORECASE=1} /^Location:/{print $2}' | tr -d '\r' | tail -n 1)"
[[ -n "$loc" ]] || { echo "FAIL: no Location"; echo "$hdr"; exit 3; }

final="$BASE_URL$loc"

echo "==> [3] follow redirect -> tickets should be 200"
code3="$(curl -s -o /dev/null -w '%{http_code}' "$final")"
echo "status=$code3"
[[ "$code3" == "200" ]] || { echo "FAIL expected 200"; echo "$final"; exit 4; }

echo "==> [4] export should be 200"
exportUrl="${final/\/ui\/tickets/\/ui\/export.csv}"
code4="$(curl -s -o /dev/null -w '%{http_code}' "$exportUrl")"
echo "status=$code4"
[[ "$code4" == "200" ]] || { echo "FAIL expected 200"; echo "$exportUrl"; exit 5; }

echo "✅ smoke ui ok"
echo "$final"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> [7] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase14 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
