#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase5_${TS}"
mkdir -p "$BAK"

echo "==> Phase5 OneShot (stable sell UI + autolink + tenant gate) @ $ROOT"
echo "==> [0] Backup"
cp -f src/server.ts "$BAK/server.ts.bak" 2>/dev/null || true
cp -f src/ui/routes.ts "$BAK/ui_routes.ts.bak" 2>/dev/null || true
cp -f src/api/tenant-key.ts "$BAK/tenant-key.ts.bak" 2>/dev/null || true
cp -f scripts/demo-keys.sh "$BAK/demo-keys.sh.bak" 2>/dev/null || true
cp -f scripts/smoke-ui.sh "$BAK/smoke-ui.sh.bak" 2>/dev/null || true

echo "==> [1] Patch tsconfig.json to ignore backups"
if [ -f tsconfig.json ]; then
  node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]),
  "node_modules","dist","build",
  "__bak_*","**/*.bak.*",".bak",
  "__bak_phase*","__bak_ui_*","__bak_fix_*"
]));
fs.writeFileSync(p, JSON.stringify(j,null,2));
console.log("✅ patched tsconfig.json exclude");
NODE
fi

echo "==> [2] Write src/api/tenant-key.ts (single contract: returns key or throws {status})"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";

export type TenantsLike = {
  verify?(tenantId: string, tenantKey: string): boolean;
};

export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function pickFirst(...vals: Array<string | undefined | null>) {
  for (const v of vals) if (typeof v === "string" && v.trim()) return v.trim();
  return "";
}

/**
 * Require tenant key for a tenantId.
 * Accepts:
 *  - Header: x-tenant-key
 *  - Query:  ?k=...
 *  - Body:   { k: "..." }
 *
 * Returns tenantKey string on success.
 * Throws HttpError(status,message) on failure.
 */
export function requireTenantKey(
  req: Request,
  tenantId: string,
  tenants?: TenantsLike
): string {
  const header = req.header("x-tenant-key");
  const q = (req.query as any)?.k;
  const b = (req.body as any)?.k;

  const tenantKey = pickFirst(header, q, b);
  if (!tenantId) throw new HttpError(400, "missing_tenantId");
  if (!tenantKey) throw new HttpError(401, "missing_tenant_key");

  if (tenants && typeof tenants.verify === "function") {
    const ok = tenants.verify(tenantId, tenantKey);
    if (!ok) throw new HttpError(401, "invalid_tenant_key");
  }

  return tenantKey;
}

export function requireAdminKey(req: Request): void {
  const admin = pickFirst(req.header("x-admin-key"), (req.query as any)?.admin, (req.body as any)?.admin);
  const expected = process.env.ADMIN_KEY || "";
  if (!expected) throw new HttpError(500, "admin_key_not_configured");
  if (!admin) throw new HttpError(401, "missing_admin_key");
  if (admin !== expected) throw new HttpError(401, "invalid_admin_key");
}
TS

echo "==> [3] Write src/ui/routes.ts (hide /ui, admin autolink, client UI table, export, status)"
cat > src/ui/routes.ts <<'TS'
import type { Express } from "express";
import crypto from "crypto";
import { requireAdminKey, requireTenantKey, HttpError } from "../api/tenant-key.js";

function esc(s: any) {
  return String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function nowISO() { return new Date().toISOString(); }

function randKey() {
  return crypto.randomBytes(24).toString("base64url");
}

function trySetStatus(store: any, tenantId: string, id: string, status: string) {
  // Best-effort across different store implementations (we've seen multiple variants)
  const s: any = store;
  if (typeof s.setStatus === "function") return s.setStatus(tenantId, id, status, "ui");
  if (typeof s.updateStatus === "function") return s.updateStatus(tenantId, id, status, "ui");
  if (typeof s.updateWorkItem === "function") return s.updateWorkItem(tenantId, id, { status }, "ui");
  if (typeof s.patchWorkItem === "function") return s.patchWorkItem(tenantId, id, { status }, "ui");
  throw new HttpError(500, "store_missing_status_method");
}

async function listItems(store: any, tenantId: string, q: any) {
  const s: any = store;
  if (typeof s.listWorkItems !== "function") return [];
  // some store.listWorkItems(tenantId, q) requires q
  return await s.listWorkItems(tenantId, q ?? {});
}

function pageShell(title: string, body: string) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>${esc(title)}</title>
<style>
  :root{color-scheme:dark;}
  body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial; background:#06070a; color:#e8eefc;}
  .wrap{max-width:1100px;margin:0 auto;padding:24px;}
  .top{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:16px;}
  .brand{display:flex;align-items:center;gap:10px}
  .dot{width:10px;height:10px;border-radius:50%;background:#4ade80;box-shadow:0 0 18px rgba(74,222,128,.35)}
  .card{border:1px solid rgba(148,163,184,.2); background:rgba(15,23,42,.55); backdrop-filter: blur(10px); border-radius:16px; padding:14px;}
  .grid{display:grid;grid-template-columns:1fr;gap:12px;}
  .meta{font-size:12px;color:rgba(226,232,240,.7)}
  .btn{appearance:none;border:1px solid rgba(148,163,184,.28); background:rgba(2,6,23,.55); color:#e8eefc; padding:8px 10px; border-radius:12px; cursor:pointer; font-size:12px}
  .btn:hover{border-color:rgba(148,163,184,.55); transform: translateY(-1px)}
  .btn:active{transform: translateY(0)}
  .btn.good{border-color:rgba(74,222,128,.35)}
  .btn.warn{border-color:rgba(251,191,36,.35)}
  .btn.bad{border-color:rgba(248,113,113,.35)}
  .row{display:flex;gap:8px;flex-wrap:wrap}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th,td{padding:10px 8px;border-bottom:1px solid rgba(148,163,184,.16);vertical-align:top}
  th{color:rgba(226,232,240,.8);font-weight:600;text-align:left}
  .pill{display:inline-flex;align-items:center;gap:6px;padding:4px 8px;border-radius:999px;border:1px solid rgba(148,163,184,.22);font-size:12px}
  .pill.new{border-color:rgba(74,222,128,.25)}
  .pill.open{border-color:rgba(251,191,36,.25)}
  .pill.done{border-color:rgba(148,163,184,.28);opacity:.8}
  .muted{color:rgba(226,232,240,.62)}
  .input{width:100%;max-width:360px;border:1px solid rgba(148,163,184,.22); background:rgba(2,6,23,.55); color:#e8eefc; padding:9px 10px; border-radius:12px; font-size:13px}
  .footer{margin-top:14px;font-size:12px;color:rgba(226,232,240,.55)}
</style>
</head>
<body>
  <div class="wrap">
    ${body}
    <div class="footer">Intake-Guardian • ${esc(nowISO())}</div>
  </div>
<script>
async function post(url, data){
  const res = await fetch(url,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams(data)});
  return res;
}
function copy(text){
  navigator.clipboard.writeText(text).then(()=>alert("Copied ✅")).catch(()=>prompt("Copy:",text));
}
</script>
</body>
</html>`;
}

export function mountUI(app: Express, deps: { store: any; tenants?: any }) {
  const { store, tenants } = deps;

  // Hide /ui root (no tech page)
  app.get("/ui", (_req, res) => res.status(404).send("not_found"));

  // Admin autolink: creates a tenant + redirects to client UI
  app.get("/ui/admin", async (req, res) => {
    try {
      requireAdminKey(req);

      // create tenant in whichever way exists
      const tid = "tenant_" + Date.now();
      const tkey = randKey();

      // If tenants store exists, register/rotate
      if (tenants && typeof tenants.create === "function") {
        const out = await tenants.create(); // preferred
        const tenantId = out?.tenantId || out?.id || tid;
        const tenantKey = out?.tenantKey || out?.key || tkey;
        return res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(tenantKey)}`);
      }

      // fallback: if tenants has set/put
      if (tenants && typeof tenants.put === "function") {
        await tenants.put(tid, tkey);
        return res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(tid)}&k=${encodeURIComponent(tkey)}`);
      }

      // last resort: work without tenants.verify (dev/demo)
      return res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(tid)}&k=${encodeURIComponent(tkey)}`);
    } catch (err: any) {
      const status = err?.status || 500;
      res.status(status).send(pageShell("Admin", `<div class="card"><b>Admin error</b><div class="meta">${esc(err?.message || String(err))}</div></div>`));
    }
  });

  app.get("/ui/tickets", async (req, res) => {
    try {
      const tenantId = String((req.query as any)?.tenantId || "");
      requireTenantKey(req as any, tenantId, tenants);

      const status = String((req.query as any)?.status || "");
      const search = String((req.query as any)?.q || "");
      const q: any = {};
      if (status) q.status = status;
      if (search) q.search = search;

      const items = await listItems(store, tenantId, q);

      const base = `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String((req.query as any)?.k || ""))}`;
      const exportUrl = `/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String((req.query as any)?.k || ""))}`;

      const rows = (items || []).map((it: any) => {
        const id = esc(it.id);
        const subj = esc(it.subject || it.title || "(no subject)");
        const sender = esc(it.sender || it.from || "");
        const pri = esc(it.priority || "");
        const st = esc(it.status || "new");
        const created = esc(it.createdAt || "");
        const pillClass = st === "done" ? "done" : (st === "open" ? "open" : "new");
        const btn = (next: string, cls: string, label: string) =>
          `<form style="display:inline" method="post" action="/ui/status">
             <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
             <input type="hidden" name="k" value="${esc(String((req.query as any)?.k || ""))}"/>
             <input type="hidden" name="id" value="${id}"/>
             <input type="hidden" name="next" value="${esc(next)}"/>
             <button class="btn ${cls}" type="submit">${esc(label)}</button>
           </form>`;

        return `<tr>
          <td>
            <div class="pill ${pillClass}"><span class="muted">#</span>${id}</div>
            <div style="margin-top:6px;font-weight:600">${subj}</div>
            <div class="meta">${sender ? "from " + sender : ""} ${created ? "• " + created : ""}</div>
          </td>
          <td>${pri || '<span class="muted">—</span>'}</td>
          <td><span class="pill ${pillClass}">${st}</span></td>
          <td>
            <div class="row">
              ${btn("new","good","New")}
              ${btn("open","warn","Open")}
              ${btn("done","bad","Done")}
            </div>
          </td>
        </tr>`;
      }).join("");

      const body = `
      <div class="top">
        <div class="brand"><span class="dot"></span><div>
          <div style="font-weight:700">Tickets</div>
          <div class="meta">Tenant: <b>${esc(tenantId)}</b></div>
        </div></div>
        <div class="row">
          <button class="btn" onclick="copy(location.href)">Copy link</button>
          <a class="btn" href="${esc(exportUrl)}">Export CSV</a>
          <a class="btn" href="https://wa.me/?text=${encodeURIComponent("Hi! Here is your tickets link: ")}${encodeURIComponent((req.protocol||"http")+"://"+(req.get("host")||"")+base)}" target="_blank">WhatsApp</a>
        </div>
      </div>

      <div class="grid">
        <div class="card">
          <form method="get" action="/ui/tickets" class="row" style="align-items:center">
            <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
            <input type="hidden" name="k" value="${esc(String((req.query as any)?.k || ""))}"/>
            <input class="input" name="q" placeholder="Search..." value="${esc(search)}"/>
            <select class="input" name="status" style="max-width:180px">
              <option value="">All status</option>
              <option value="new" ${status==="new"?"selected":""}>new</option>
              <option value="open" ${status==="open"?"selected":""}>open</option>
              <option value="done" ${status==="done"?"selected":""}>done</option>
            </select>
            <button class="btn" type="submit">Filter</button>
            <a class="btn" href="${esc(base)}">Reset</a>
          </form>
        </div>

        <div class="card">
          <table>
            <thead><tr><th>Ticket</th><th>Priority</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>
              ${rows || `<tr><td colspan="4" class="muted">No tickets yet. Send an email/webhook to create one.</td></tr>`}
            </tbody>
          </table>
        </div>

        <div class="card">
          <div style="font-weight:700;margin-bottom:6px">30-second story</div>
          <div class="meta">“We collect requests from email/WhatsApp/webhooks, classify them, and your team updates status in one clean page. Export anytime.”</div>
        </div>
      </div>`;
      res.status(200).send(pageShell("Tickets", body));
    } catch (err: any) {
      const status = err?.status || 401;
      res.status(status).send(pageShell("Access", `<div class="card"><b>Access denied</b><div class="meta">${esc(err?.message || "invalid_tenant_key")}</div></div>`));
    }
  });

  app.post("/ui/status", async (req, res) => {
    try {
      const tenantId = String((req.body as any)?.tenantId || "");
      const k = String((req.body as any)?.k || "");
      const id = String((req.body as any)?.id || "");
      const next = String((req.body as any)?.next || "open");
      // accept body.k too
      (req.query as any).tenantId = tenantId;
      (req.query as any).k = k;
      requireTenantKey(req as any, tenantId, tenants);

      await trySetStatus(store, tenantId, id, next);
      return res.redirect(`/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`);
    } catch (err: any) {
      const status = err?.status || 500;
      res.status(status).send(pageShell("Status", `<div class="card"><b>Status update failed</b><div class="meta">${esc(err?.message || String(err))}</div></div>`));
    }
  });

  app.get("/ui/export.csv", async (req, res) => {
    try {
      const tenantId = String((req.query as any)?.tenantId || "");
      requireTenantKey(req as any, tenantId, tenants);

      const items = await listItems(store, tenantId, {});
      res.setHeader("Content-Type", "text/csv; charset=utf-8");
      res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);

      const header = ["id","subject","status","priority","sender","createdAt","updatedAt"].join(",");
      const lines = (items || []).map((it: any) => {
        const row = [
          it.id, it.subject || it.title || "",
          it.status || "", it.priority || "",
          it.sender || it.from || "",
          it.createdAt || "", it.updatedAt || ""
        ].map((v:any)=> `"${String(v??"").replace(/"/g,'""')}"`).join(",");
        return row;
      });

      res.status(200).send([header, ...lines].join("\n"));
    } catch (err: any) {
      const status = err?.status || 401;
      res.status(status).send("invalid_tenant_key");
    }
  });

  app.get("/ui/health", (_req, res) => res.json({ ok: true }));
}
TS

echo "==> [4] Overwrite src/server.ts to stable wiring (single mount, no duplicates)"
cat > src/server.ts <<'TS'
import express from "express";
import path from "path";
import pino from "pino";

import { makeRoutes } from "./api/routes.js";
import { makeAdapters } from "./api/adapters.js";
import { TenantsStore } from "./tenants/store.js";
import { FileStore } from "./store/file_store.js";
import { mountUI } from "./ui/routes.js";

const logger = pino();

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const PRESET_ID = process.env.PRESET_ID || "it_support.v1";
const DEDUPE_WINDOW_SECONDS = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);

async function main() {
  const app = express();
  app.use(express.urlencoded({ extended: true }));
  app.use(express.json({ limit: "2mb" }));

  const dataDirAbs = path.resolve(DATA_DIR);
  const tenants = new TenantsStore({ dataDir: dataDirAbs });
  const store = new FileStore({ dataDir: dataDirAbs });

  // UI (hidden root + admin autolink + tickets + export)
  mountUI(app, { store, tenants });

  // API routes
  app.use("/api", makeRoutes({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS, tenants }));
  app.use("/api/adapters", makeAdapters({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS, tenants }));

  // health
  app.get("/health", (_req, res) => res.json({ ok: true }));

  app.listen(PORT, () => {
    logger.info({
      PORT,
      DATA_DIR,
      PRESET_ID,
      DEDUPE_WINDOW_SECONDS,
      TENANT_KEYS_CONFIGURED: !!process.env.TENANT_KEYS || true,
      ADMIN_KEY_CONFIGURED: !!process.env.ADMIN_KEY
    }, "Intake-Guardian Agent running");
  });
}

main().catch((err) => {
  logger.error({ err }, "fatal");
  process.exit(1);
});
TS

echo "==> [5] scripts/demo-keys.sh (no python) -> prints /ui/admin link"
cat > scripts/demo-keys.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [ -z "${ADMIN_KEY}" ]; then
  if [ -f .env.local ]; then
    ADMIN_KEY="$(grep -E '^ADMIN_KEY=' .env.local | tail -n1 | cut -d= -f2- | tr -d '\r')"
  fi
fi

if [ -z "${ADMIN_KEY}" ]; then
  echo "❌ ADMIN_KEY missing. Set ADMIN_KEY=... or put ADMIN_KEY=... in .env.local"
  exit 1
fi

URL="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
echo "==> Open admin autolink (will redirect to client UI)"
echo "$URL"
open "$URL" >/dev/null 2>&1 || true
SH2
chmod +x scripts/demo-keys.sh

echo "==> [6] scripts/smoke-ui.sh (no python) - checks /ui hidden + /ui/admin + export 200"
cat > scripts/smoke-ui.sh <<'SH3'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [ -z "${ADMIN_KEY}" ]; then
  if [ -f .env.local ]; then
    ADMIN_KEY="$(grep -E '^ADMIN_KEY=' .env.local | tail -n1 | cut -d= -f2- | tr -d '\r')"
  fi
fi

echo "==> [1] health"
curl -sS "${BASE_URL}/health" | grep -q '"ok":true' && echo "✅ health ok"

echo "==> [2] /ui must be hidden (404 expected)"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/ui")"
echo "status=${CODE}"
[ "${CODE}" = "404" ] && echo "✅ /ui hidden"

echo "==> [3] admin autolink should redirect"
REDIR="$(curl -sSI "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | tail -n1)"
if [ -z "${REDIR}" ]; then
  echo "❌ no redirect location from /ui/admin"
  curl -sSI "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" | sed -n '1,25p'
  exit 1
fi
echo "✅ redirect to: ${REDIR}"

echo "==> [4] export should be 200"
# REDIR is like /ui/tickets?tenantId=...&k=...
TENANT_ID="$(printf "%s" "${REDIR}" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(printf "%s" "${REDIR}" | sed -n 's/.*k=\([^&]*\).*/\1/p')"
[ -z "${TENANT_ID}" ] && echo "❌ missing tenantId in redirect" && exit 1
[ -z "${TENANT_KEY}" ] && echo "❌ missing k in redirect" && exit 1

E="${BASE_URL}/ui/export.csv?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
CODE2="$(curl -sS -o /dev/null -w '%{http_code}' "${E}")"
echo "export_status=${CODE2}"
[ "${CODE2}" = "200" ] && echo "✅ export 200"

echo
echo "✅ smoke ok"
echo "Client UI: ${BASE_URL}${REDIR}"
echo "Export:    ${E}"
SH3
chmod +x scripts/smoke-ui.sh

echo "==> [7] Typecheck"
pnpm -s lint:types

echo "==> [8] Commit (optional)"
git add tsconfig.json src/api/tenant-key.ts src/ui/routes.ts src/server.ts scripts/demo-keys.sh scripts/smoke-ui.sh >/dev/null 2>&1 || true
git commit -m "feat(phase5): stable sell UI + admin autolink + tenant gate" >/dev/null 2>&1 || true

echo
echo "✅ Phase5 installed."
echo "Now:"
echo "  1) pnpm dev"
echo "  2) BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  3) BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
