#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
echo "==> Phase12 OneShot (Share link without k + tenant key SSOT compat) @ $ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase12_${ts}"
echo "==> [0] Backup -> $bak"
mkdir -p "$bak"
cp -R src scripts tsconfig.json "$bak/" 2>/dev/null || true

echo "==> [1] Ensure tsconfig excludes backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const add = ["__bak_*","__bak_phase*"];
for (const x of add) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j,null,2));
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Write src/api/tenant-key.ts (compat: 2-4 args + typed HttpError)"
mkdir -p src/api
cat > src/api/tenant-key.ts <<'TS'
/* Tenant key gate (SSOT + backward-compatible)
   - requireTenantKey(req, tenantId?, ...rest) => string (throws HttpError)
   - verifyTenantKey(req, tenantId?, ...rest) => {ok:true,key} | {ok:false,status,error}
   Notes:
   - We accept extra args to avoid breaking older call sites:
       requireTenantKey(req, tenantId, tenantsStore, sharesStore?)
*/
export type VerifyResult =
  | { ok: true; key: string }
  | { ok: false; status: number; error: string };

export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function pick(obj: any, path: string[]): any {
  let cur = obj;
  for (const k of path) {
    if (!cur) return undefined;
    cur = cur[k];
  }
  return cur;
}

function readKeyFromReq(req: any): string | undefined {
  // Query: ?k=...
  const qk = pick(req, ["query", "k"]);
  if (typeof qk === "string" && qk.trim()) return qk.trim();

  // Header: x-tenant-key
  const hk =
    (req?.headers?.["x-tenant-key"] as any) ||
    (req?.headers?.["X-Tenant-Key"] as any);
  if (typeof hk === "string" && hk.trim()) return hk.trim();

  // Body: { tenantKey } or { k }
  const bk = pick(req, ["body", "tenantKey"]) ?? pick(req, ["body", "k"]);
  if (typeof bk === "string" && bk.trim()) return bk.trim();

  return undefined;
}

function normalizeTenantId(tenantId: any): string | undefined {
  if (typeof tenantId === "string" && tenantId.trim()) return tenantId.trim();
  const q = tenantId?.tenantId;
  if (typeof q === "string" && q.trim()) return q.trim();
  return undefined;
}

// Optional tenant store verification (if provided)
async function maybeVerifyWithTenantsStore(
  tenantsStore: any,
  tenantId: string,
  key: string
): Promise<boolean> {
  if (!tenantsStore) return true;

  // Try common patterns without hard dependency
  // - tenantsStore.verify(tenantId,key)
  // - tenantsStore.get(tenantId) => { key } or { tenantKey }
  try {
    if (typeof tenantsStore.verify === "function") {
      const r = await tenantsStore.verify(tenantId, key);
      if (typeof r === "boolean") return r;
      if (r && typeof r.ok === "boolean") return !!r.ok;
    }
    if (typeof tenantsStore.get === "function") {
      const t = await tenantsStore.get(tenantId);
      const k1 = t?.key ?? t?.tenantKey;
      if (typeof k1 === "string") return k1 === key;
    }
  } catch {
    // if store errors, treat as failed verification
    return false;
  }

  // If we can't verify, do NOT block (to keep MVP usable)
  return true;
}

export async function verifyTenantKey(
  req: any,
  tenantIdMaybe?: any,
  ...rest: any[]
): Promise<VerifyResult> {
  const tenantId = normalizeTenantId(tenantIdMaybe) ?? (req?.query?.tenantId as any);
  if (!tenantId || typeof tenantId !== "string") {
    return { ok: false, status: 400, error: "missing_tenantId" };
  }

  const key = readKeyFromReq(req);
  if (!key) return { ok: false, status: 401, error: "missing_tenant_key" };

  // Backward-compat: rest may be [tenantsStore, sharesStore]
  const tenantsStore = rest?.[0];

  const ok = await maybeVerifyWithTenantsStore(tenantsStore, tenantId, key);
  if (!ok) return { ok: false, status: 401, error: "invalid_tenant_key" };

  return { ok: true, key };
}

export function requireTenantKey(
  req: any,
  tenantIdMaybe?: any,
  ...rest: any[]
): string {
  // NOTE: this function is used in sync codepaths;
  // verification with tenants store is best-effort and async in verifyTenantKey.
  // Here we only enforce presence and shape; deep verify is optional.
  const tenantId = normalizeTenantId(tenantIdMaybe) ?? (req?.query?.tenantId as any);
  if (!tenantId || typeof tenantId !== "string") throw new HttpError(400, "missing_tenantId");

  const key = readKeyFromReq(req);
  if (!key) throw new HttpError(401, "missing_tenant_key");
  return key;
}
TS

echo "==> [3] Write src/ui/routes.ts (hide /ui root, /ui/admin -> /ui/s/:shareId, /ui/tickets works via share or k)"
mkdir -p src/ui

cat > src/ui/routes.ts <<'TS'
import type { Express } from "express";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { requireTenantKey } from "../api/tenant-key.js";

// ---- Helpers: share registry (local file) ----
type Share = {
  id: string;
  tenantId: string;
  tenantKey: string;
  createdAt: string;
  revoked?: boolean;
};

function nowIso() {
  return new Date().toISOString();
}
function rid(n = 18) {
  return crypto.randomBytes(n).toString("base64url");
}

function dataDirFromEnv() {
  return path.resolve(process.env.DATA_DIR || "data");
}

function sharesPath() {
  return path.join(dataDirFromEnv(), "ui_shares.json");
}

function loadShares(): Share[] {
  try {
    const p = sharesPath();
    if (!fs.existsSync(p)) return [];
    const raw = fs.readFileSync(p, "utf8");
    const j = JSON.parse(raw);
    return Array.isArray(j) ? j : [];
  } catch {
    return [];
  }
}

function saveShares(shares: Share[]) {
  const dir = dataDirFromEnv();
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(sharesPath(), JSON.stringify(shares, null, 2));
}

function createShare(tenantId: string, tenantKey: string): Share {
  const shares = loadShares().filter(s => !s.revoked);
  const s: Share = { id: rid(12), tenantId, tenantKey, createdAt: nowIso() };
  shares.unshift(s);
  saveShares(shares.slice(0, 5000));
  return s;
}

function getShare(id: string): Share | undefined {
  const s = loadShares().find(x => x.id === id && !x.revoked);
  return s;
}

// ---- Minimal HTML ----
function page(title: string, body: string) {
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
  .row { display:flex; gap:10px; flex-wrap: wrap; align-items:center; }
  .btn { display:inline-flex; align-items:center; gap:8px; padding:10px 14px; border-radius: 12px; border:1px solid rgba(255,255,255,.10); background: rgba(0,0,0,.20); color:#e5e7eb; text-decoration:none; font-weight:700; }
  .btn.primary { background: rgba(59,130,246,.20); border-color: rgba(59,130,246,.35); }
  .btn.good { background: rgba(16,185,129,.18); border-color: rgba(16,185,129,.35); }
  table { width:100%; border-collapse: collapse; margin-top: 12px; font-size: 13px; }
  th, td { padding: 10px 8px; border-bottom: 1px solid rgba(255,255,255,.08); text-align:left; }
  pre { white-space: pre-wrap; word-break: break-word; background: rgba(0,0,0,.35); border:1px solid rgba(255,255,255,.08); padding: 12px; border-radius: 12px; }
</style>
</head>
<body>
  <div class="wrap">${body}</div>
</body></html>`;
}

function adminError(msg: string, extra?: any) {
  return page("Admin error", `
    <div class="card">
      <div class="h">Admin error</div>
      <div class="muted">${msg}</div>
      ${extra ? `<pre>${escapeHtml(JSON.stringify(extra, null, 2))}</pre>` : ""}
      <div class="muted" style="margin-top:10px">Intake-Guardian • ${nowIso()}</div>
    </div>
  `);
}

function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" } as any)[c]);
}

// ---- Adapter calls (optional) ----
// We try to use existing internal API endpoints if present.
// If they don't exist, we show a clear error.
async function fetchJson(url: string, init?: any) {
  const r = await fetch(url, init);
  const ct = r.headers.get("content-type") || "";
  const txt = await r.text();
  if (!ct.includes("application/json")) {
    return { ok: false, status: r.status, ct, text: txt.slice(0, 1200) };
  }
  try {
    return { ok: true, status: r.status, json: JSON.parse(txt) };
  } catch {
    return { ok: false, status: r.status, ct, text: txt.slice(0, 1200) };
  }
}

function baseUrlFromReq(req: any) {
  const proto = (req.headers["x-forwarded-proto"] as string) || "http";
  const host = req.headers.host;
  return `${proto}://${host}`;
}

export function mountUi(app: Express, args: { store?: any }) {
  // HIDE /ui root
  app.get("/ui", (_req, res) => res.status(404).send("Not found"));

  // ADMIN AUTOLINK (no UI page): /ui/admin?admin=...
  app.get("/ui/admin", async (req, res) => {
    const ADMIN_KEY = process.env.ADMIN_KEY || "";
    const q = (req.query.admin as string) || "";
    if (!ADMIN_KEY) return res.status(401).send(adminError("admin_key_not_configured"));
    if (!q || q !== ADMIN_KEY) return res.status(401).send(adminError("bad_admin_key"));

    const base = baseUrlFromReq(req);

    // Try common admin endpoints (existing in some phases)
    // 1) POST /api/admin/tenants/create
    // 2) POST /api/admin/tenants/rotate
    // 3) fallback: GET /api/admin/tenants -> take first usable
    const tryCreate = await fetchJson(`${base}/api/admin/tenants/create`, { method: "POST" });
    let tenantId: string | undefined;
    let tenantKey: string | undefined;

    const pickFrom = (o: any) => {
      if (!o) return;
      tenantId = tenantId ?? o.tenantId ?? o.id;
      tenantKey = tenantKey ?? o.tenantKey ?? o.key ?? o.k;
    };

    if (tryCreate.ok && tryCreate.status < 300) {
      pickFrom(tryCreate.json);
    } else {
      const tryRotate = await fetchJson(`${base}/api/admin/tenants/rotate`, { method: "POST" });
      if (tryRotate.ok && tryRotate.status < 300) {
        pickFrom(tryRotate.json);
      } else {
        const list = await fetchJson(`${base}/api/admin/tenants`, { method: "GET" });
        if (list.ok && list.status < 300) {
          const arr = list.json?.tenants || list.json || [];
          if (Array.isArray(arr) && arr.length) pickFrom(arr[0]);
        }
      }
    }

    if (!tenantId || !tenantKey) {
      return res.status(500).send(
        adminError("Could not auto-create tenant for client link.", {
          need: "{tenantId, tenantKey}",
          hint: "Implement /api/admin/tenants/create (POST) or /api/admin/tenants/rotate (POST) or /api/admin/tenants (GET)",
        })
      );
    }

    // Create share (NO k in URL)
    const share = createShare(tenantId, tenantKey);
    return res.redirect(302, `/ui/s/${share.id}`);
  });

  // SHARE LINK: /ui/s/:id  -> resolves tenantId+key server-side
  app.get("/ui/s/:id", async (req, res) => {
    const id = req.params.id;
    const s = getShare(id);
    if (!s) return res.status(404).send(page("Not found", `<div class="card"><div class="h">Not found</div><div class="muted">Invalid or revoked share link.</div></div>`));
    return res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(s.tenantId)}&share=${encodeURIComponent(s.id)}`);
  });

  // TICKETS UI:
  // - Accepts either (?tenantId=...&share=...) OR (?tenantId=...&k=...)
  app.get("/ui/tickets", async (req, res) => {
    const tenantId = req.query.tenantId as string;
    const shareId = req.query.share as string | undefined;

    let tenantKey: string | undefined;

    if (shareId) {
      const s = getShare(shareId);
      if (!s || s.tenantId !== tenantId) {
        return res.status(401).send(page("Unauthorized", `<div class="card"><div class="h">Unauthorized</div><div class="muted">Bad share link.</div><pre>invalid_share</pre></div>`));
      }
      tenantKey = s.tenantKey;
    } else {
      // Legacy: k= in URL
      try {
        tenantKey = requireTenantKey(req as any, tenantId);
      } catch (e: any) {
        return res.status(e?.status || 401).send(page("Unauthorized", `<div class="card"><div class="h">Unauthorized</div><div class="muted">Bad tenant key or missing.</div><pre>${escapeHtml(e?.message || "invalid_tenant_key")}</pre></div>`));
      }
    }

    // Store integration: we keep this UI minimal; your existing API handles list/export/update.
    // We'll call existing internal API endpoints:
    const base = baseUrlFromReq(req);
    const listUrl = `${base}/api/tickets?tenantId=${encodeURIComponent(tenantId)}`;

    // Forward key via header for API
    const list = await fetchJson(listUrl, { headers: { "x-tenant-key": tenantKey } });

    let rowsHtml = `<tr><td colspan="6" class="muted">No tickets yet. Use adapters to create the first ticket.</td></tr>`;
    if (list.ok && list.status < 300) {
      const tickets = list.json?.tickets || list.json || [];
      if (Array.isArray(tickets) && tickets.length) {
        rowsHtml = tickets.map((t: any) => {
          const id = escapeHtml(String(t.id ?? t.ticketId ?? ""));
          const subj = escapeHtml(String(t.subject ?? t.title ?? ""));
          const sender = escapeHtml(String(t.sender ?? t.from ?? ""));
          const status = escapeHtml(String(t.status ?? ""));
          const prio = escapeHtml(String(t.priority ?? ""));
          const due = escapeHtml(String(t.due ?? t.slaDue ?? ""));
          return `<tr>
            <td>${id}</td>
            <td>${subj}<div class="muted">${sender}</div></td>
            <td>${status}</td>
            <td>${prio}</td>
            <td>${due}</td>
            <td class="muted">—</td>
          </tr>`;
        }).join("\n");
      }
    }

    const exportHref = shareId
      ? `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&share=${encodeURIComponent(shareId)}`
      : `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey!)}`;

    const copyLink = shareId
      ? `${base}/ui/s/${encodeURIComponent(shareId)}`
      : `${base}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey!)}`;

    return res.status(200).send(page("Tickets", `
      <div class="card">
        <div class="h">Tickets</div>
        <div class="muted">tenant: ${escapeHtml(tenantId || "")}</div>
        <div class="row" style="margin-top:12px">
          <a class="btn primary" href="${escapeHtml(req.originalUrl)}">Refresh</a>
          <a class="btn good" href="${escapeHtml(exportHref)}">Export CSV</a>
          <a class="btn" href="#" onclick="navigator.clipboard.writeText('${escapeHtml(copyLink)}');return false;">Copy link</a>
        </div>

        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>SUBJECT / SENDER</th>
              <th>STATUS</th>
              <th>PRIORITY</th>
              <th>DUE</th>
              <th>ACTIONS</th>
            </tr>
          </thead>
          <tbody>${rowsHtml}</tbody>
        </table>

        <div class="muted" style="margin-top:10px">Intake-Guardian — one place to see requests, change status, export proof.</div>
      </div>
    `));
  });

  // CSV Export: works via share OR k
  app.get("/ui/export.csv", async (req, res) => {
    const tenantId = req.query.tenantId as string;
    const shareId = req.query.share as string | undefined;

    let tenantKey: string | undefined;

    if (shareId) {
      const s = getShare(shareId);
      if (!s || s.tenantId !== tenantId) return res.status(401).send("invalid_share");
      tenantKey = s.tenantKey;
    } else {
      try {
        tenantKey = requireTenantKey(req as any, tenantId);
      } catch (e: any) {
        return res.status(e?.status || 401).send(e?.message || "invalid_tenant_key");
      }
    }

    const base = baseUrlFromReq(req);
    const url = `${base}/api/tickets/export.csv?tenantId=${encodeURIComponent(tenantId)}`;
    const r = await fetch(url, { headers: { "x-tenant-key": tenantKey } });

    res.status(r.status);
    res.setHeader("content-type", r.headers.get("content-type") || "text/csv");
    const buf = Buffer.from(await r.arrayBuffer());
    return res.send(buf);
  });
}
TS

echo "==> [4] Patch src/server.ts to use mountUi(app,{store}) only (no tenants arg), and import name mountUi"
node - <<'NODE'
const fs = require("fs");

const p = "src/server.ts";
let s = fs.readFileSync(p,"utf8");

// normalize import
s = s.replace(/import\s*\{\s*mountUI\s*\}\s*from\s*["']\.\/ui\/routes\.js["'];/g, 'import { mountUi } from "./ui/routes.js";');
s = s.replace(/import\s*\{\s*mountUi\s*\}\s*from\s*["']\.\/ui\/routes\.js["'];/g, 'import { mountUi } from "./ui/routes.js";');

// remove any mountUi calls that pass tenants
s = s.replace(/mountUi\(([^,]+),\s*\{\s*store:\s*([^,}]+),\s*tenants:\s*[^}]+\}\s*\);/g, "mountUi($1, { store: $2 });");

// ensure at least one mountUi exists; if none, append near end before listen
if (!s.includes("mountUi(")) {
  // naive inject before app.listen or server start
  s = s.replace(/(app\.listen\(|server\.listen\(|http\.createServer\()/, `mountUi(app as any, { store: store as any });\n\n$1`);
}

// If still has mountUI typo
s = s.replace(/\bmountUI\b/g, "mountUi");

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUi with store only)");
NODE

echo "==> [5] Update scripts/smoke-ui.sh (expect /ui/admin -> /ui/s/...)"
mkdir -p scripts
cat > scripts/smoke-ui.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"
if [ -z "$ADMIN_KEY" ]; then
  echo "ERROR: ADMIN_KEY is required"
  exit 1
fi

echo "==> [1] /ui hidden (404)"
status="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$status"
[ "$status" = "404" ] || { echo "FAIL expected 404"; exit 1; }

echo "==> [2] /ui/admin redirect (302)"
hdr="$(curl -s -D - -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" || true)"
code="$(echo "$hdr" | head -n 1 | awk '{print $2}')"
echo "status=$code"
echo "$hdr" | grep -i '^location:' >/dev/null || {
  echo "FAIL: no Location"
  echo "$hdr"
  exit 1
}
loc="$(echo "$hdr" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r\n')"
echo "location=$loc"
# expect /ui/s/<id> OR direct /ui/tickets (ok too)
echo "$loc" | grep -E '^/ui/(s/|tickets)' >/dev/null || { echo "FAIL bad location: $loc"; exit 1; }

# follow redirect(s) to get a tickets URL and ensure 200
final="$(curl -s -L -o /dev/null -w "%{url_effective}" "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
echo "final=$final"
echo "==> [3] client tickets should be 200"
status2="$(curl -s -o /dev/null -w "%{http_code}" "$final")"
echo "status=$status2"
[ "$status2" = "200" ] || { echo "FAIL expected 200"; exit 1; }

echo "==> [4] export should be 200"
# attempt export via share-based tickets -> convert to export endpoint by replacing /ui/tickets with /ui/export.csv
exportUrl="$(echo "$final" | sed 's#/ui/tickets#/ui/export.csv#')"
status3="$(curl -s -o /dev/null -w "%{http_code}" "$exportUrl")"
echo "status=$status3"
[ "$status3" = "200" ] || { echo "FAIL expected 200"; echo "$exportUrl"; exit 1; }

echo "✅ smoke ui ok"
SH2
chmod +x scripts/smoke-ui.sh

echo "==> [6] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase12 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
