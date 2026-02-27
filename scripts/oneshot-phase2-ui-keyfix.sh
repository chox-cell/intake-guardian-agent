#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$PWD}"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
BK="__bak_phase2_${ts}"
mkdir -p "$BK"

backup() {
  local f="$1"
  if [ -f "$f" ]; then
    mkdir -p "$BK/$(dirname "$f")"
    cp -v "$f" "$BK/$f" >/dev/null
  fi
}

echo "==> Phase2 OneShot @ $ROOT"
echo "==> [0] backups -> $BK"
backup src/api/tenant-key.ts
backup src/api/ui_v6.ts
backup src/server.ts
backup tsconfig.json
backup package.json

echo "==> [1] Ensure tsconfig ignores backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]),
  "node_modules","dist","build",
  "__bak_*","**/*.bak.*",".bak","__bak_phase2_*"
]));
fs.writeFileSync(p, JSON.stringify(j,null,2));
console.log("✅ patched", p);
NODE

echo "==> [2] Write robust tenant-key gate (accept header OR ?k= OR body.k)"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";
import type { TenantsStore } from "../tenants/store.js";

function safeJson(s: string) {
  try { return JSON.parse(s); } catch { return null; }
}

function getKeyFromReq(req: Request): string {
  const h = (req.header("x-tenant-key") || "").trim();
  if (h) return h;

  // UI links: /ui/...?k=TENANT_KEY
  const q = (typeof req.query.k === "string" ? req.query.k : "").trim();
  if (q) return q;

  // optional: body.k
  const b = (req.body && typeof (req.body as any).k === "string" ? (req.body as any).k : "").trim();
  if (b) return b;

  return "";
}

export function requireTenantKey(req: Request, tenantId: string, tenantsStore?: TenantsStore) {
  const key = getKeyFromReq(req);

  if (!key) {
    return { ok: false as const, status: 401, error: "missing_tenant_key" as const };
  }

  // Preferred: TenantsStore (dynamic tenants created via admin)
  if (tenantsStore) {
    const ok = tenantsStore.verify(tenantId, key);
    if (!ok) return { ok: false as const, status: 401, error: "invalid_tenant_key" as const };
    return { ok: true as const, status: 200, key };
  }

  // Fallback: TENANT_KEYS_JSON for dev
  const raw = (process.env.TENANT_KEYS_JSON || "").trim();
  if (!raw) {
    return { ok: false as const, status: 500, error: "tenant_keys_not_configured" as const };
  }
  const obj = safeJson(raw);
  const expected = obj && typeof obj[tenantId] === "string" ? String(obj[tenantId]) : "";
  if (!expected || expected !== key) {
    return { ok: false as const, status: 401, error: "invalid_tenant_key" as const };
  }
  return { ok: true as const, status: 200, key };
}
TS

echo "==> [3] Write UI v6 (clean table + status buttons + export + copy link + CTA)"
cat > src/api/ui_v6.ts <<'TS'
import { Router } from "express";
import { z } from "zod";
import type { Store } from "./routes.js"; // we only need runtime store, type safety via any
import type { TenantsStore } from "../tenants/store.js";
import { requireTenantKey } from "./tenant-key.js";

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function fmtIso(s?: string) {
  if (!s) return "";
  try {
    const d = new Date(s);
    return isNaN(d.getTime()) ? s : d.toISOString().replace("T"," ").slice(0,19) + "Z";
  } catch { return s; }
}

function csvEscape(v: any) {
  const s = String(v ?? "");
  if (/[,"\n]/.test(s)) return `"${s.replaceAll('"','""')}"`;
  return s;
}

export function makeUiRoutes(args: { store: any; tenants?: TenantsStore; publicBaseUrl?: string }) {
  const r = Router();

  r.get("/", (req, res) => {
    const base = (args.publicBaseUrl || "").trim() || `${req.protocol}://${req.get("host")}`;
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Intake-Guardian UI</title>
<style>
  body{font-family:ui-sans-serif,system-ui,Arial; background:#0b1220; color:#e5e7eb; margin:0}
  .wrap{max-width:1100px;margin:0 auto;padding:24px}
  .card{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.10);border-radius:14px;padding:16px}
  .row{display:flex;gap:12px;flex-wrap:wrap}
  input{background:#0a0f1a;border:1px solid rgba(255,255,255,.14);color:#e5e7eb;border-radius:10px;padding:10px 12px;outline:none;width:320px}
  .btn{cursor:pointer;background:#1f6feb;border:0;color:white;border-radius:10px;padding:10px 12px;font-weight:600}
  .muted{color:#9ca3af;font-size:13px}
  a{color:#93c5fd}
</style></head>
<body><div class="wrap">
  <h1 style="margin:0 0 6px 0">Intake-Guardian (UI)</h1>
  <div class="muted" style="margin-bottom:14px">Paste tenantId + key → open tickets + export CSV.</div>

  <div class="card">
    <div class="row">
      <input id="tenantId" placeholder="tenantId (ex: tenant_...)" />
      <input id="k" placeholder="tenant key (k=...)" />
      <button class="btn" onclick="go()">Open Tickets</button>
      <button class="btn" style="background:#10b981" onclick="csv()">Export CSV</button>
    </div>
    <div class="muted" style="margin-top:10px">
      Example link format:
      <br><code>${esc(base)}/ui/tickets?tenantId=TENANT_ID&k=TENANT_KEY</code>
    </div>
  </div>

<script>
function go(){
  const t=document.getElementById('tenantId').value.trim();
  const k=document.getElementById('k').value.trim();
  if(!t||!k) return alert('missing tenantId or key');
  location.href='/ui/tickets?tenantId='+encodeURIComponent(t)+'&k='+encodeURIComponent(k);
}
function csv(){
  const t=document.getElementById('tenantId').value.trim();
  const k=document.getElementById('k').value.trim();
  if(!t||!k) return alert('missing tenantId or key');
  location.href='/ui/export.csv?tenantId='+encodeURIComponent(t)+'&k='+encodeURIComponent(k);
}
</script>
</div></body></html>`);
  });

  r.get("/tickets", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${tk.error}</pre>`);

    const q = {
      status: (typeof req.query.status === "string" ? req.query.status : undefined),
      limit: Number(req.query.limit || 200),
      offset: 0,
      search: (typeof req.query.search === "string" ? req.query.search : undefined)
    };

    const items = await args.store.listWorkItems(tenantId, q);

    const baseUrl = (args.publicBaseUrl || "").trim() || `${req.protocol}://${req.get("host")}`;
    const link = `${baseUrl}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(req.query.k||""))}`;
    const exportLink = `${baseUrl}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(req.query.k||""))}`;

    res.setHeader("Content-Type","text/html; charset=utf-8");
    res.end(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tickets • ${esc(tenantId)}</title>
<style>
  body{font-family:ui-sans-serif,system-ui,Arial;background:#0b1220;color:#e5e7eb;margin:0}
  .wrap{max-width:1200px;margin:0 auto;padding:24px}
  .top{display:flex;gap:12px;flex-wrap:wrap;align-items:center;justify-content:space-between;margin-bottom:14px}
  .pill{font-size:12px;color:#93c5fd;background:rgba(147,197,253,.12);border:1px solid rgba(147,197,253,.22);padding:6px 10px;border-radius:999px}
  .btn{cursor:pointer;background:#1f6feb;border:0;color:white;border-radius:10px;padding:10px 12px;font-weight:700}
  .btn2{cursor:pointer;background:#10b981;border:0;color:white;border-radius:10px;padding:10px 12px;font-weight:700}
  .card{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.10);border-radius:14px;padding:14px}
  table{width:100%;border-collapse:collapse}
  th,td{padding:10px 10px;border-bottom:1px solid rgba(255,255,255,.10);text-align:left;font-size:13px;vertical-align:top}
  th{color:#9ca3af;font-weight:600}
  .muted{color:#9ca3af;font-size:12px}
  .actions{display:flex;gap:6px;flex-wrap:wrap}
  .sbtn{cursor:pointer;background:#111827;border:1px solid rgba(255,255,255,.14);color:#e5e7eb;border-radius:10px;padding:6px 8px;font-size:12px}
  .sbtn:hover{border-color:rgba(255,255,255,.25)}
  code{background:rgba(0,0,0,.35);padding:2px 6px;border-radius:8px}
  a{color:#93c5fd}
</style></head>
<body><div class="wrap">
  <div class="top">
    <div>
      <div style="font-size:22px;font-weight:800">Tickets</div>
      <div class="muted">tenantId: <code>${esc(tenantId)}</code> • total: <code>${items.length}</code></div>
    </div>
    <div style="display:flex;gap:10px;flex-wrap:wrap">
      <button class="btn" onclick="copyLink()">Copy UI Link</button>
      <a class="btn2" href="${esc(exportLink)}" style="text-decoration:none;display:inline-block">Export CSV</a>
      <a class="pill" href="/ui" style="text-decoration:none">Change tenant</a>
    </div>
  </div>

  <div class="card" style="margin-bottom:14px">
    <div class="muted">Share this with the client:</div>
    <div style="margin-top:6px"><code id="share">${esc(link)}</code></div>
  </div>

  <div class="card">
    <table>
      <thead>
        <tr>
          <th>Id</th>
          <th>Subject / Sender</th>
          <th>Status</th>
          <th>Priority</th>
          <th>SLA / Due</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        ${items.map((it:any)=>`
          <tr>
            <td><code>${esc(it.id)}</code><div class="muted">${esc(it.source||"")}</div></td>
            <td>
              <div style="font-weight:700">${esc(it.subject||"(no subject)")}</div>
              <div class="muted">${esc(it.sender||"")}</div>
            </td>
            <td><code>${esc(it.status)}</code></td>
            <td><code>${esc(it.priority)}</code><div class="muted">${esc(it.category||"")}</div></td>
            <td>
              <div class="muted">SLA: ${esc(it.slaSeconds)}s</div>
              <div><code>${esc(fmtIso(it.dueAt))}</code></div>
            </td>
            <td>
              <form method="POST" action="/ui/status" class="actions">
                <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
                <input type="hidden" name="k" value="${esc(String(req.query.k||""))}"/>
                <input type="hidden" name="id" value="${esc(it.id)}"/>
                <button class="sbtn" name="next" value="new">new</button>
                <button class="sbtn" name="next" value="in_progress">in_progress</button>
                <button class="sbtn" name="next" value="done">done</button>
                <button class="sbtn" name="next" value="blocked">blocked</button>
              </form>
            </td>
          </tr>
        `).join("")}
      </tbody>
    </table>

    ${items.length===0 ? `<div class="muted" style="padding:12px">No tickets yet. Send an email/whatsapp intake to create one.</div>` : ``}
  </div>

  <div style="margin-top:14px" class="muted">
    Demo CTA: send “Hi Intake-Guardian, I want a demo” on WhatsApp (hook later) or email: <code>${esc(process.env.CONTACT_EMAIL || process.env.RESEND_FROM || "support@yourdomain.com")}</code>
  </div>

<script>
async function copyLink(){
  const t = document.getElementById('share').innerText;
  try { await navigator.clipboard.writeText(t); alert('Copied'); }
  catch { prompt('Copy this link:', t); }
}
</script>
</div></body></html>`);
  });

  // Status update (best-effort): use store method if exists; otherwise 501 (but UI won’t crash)
  r.post("/status", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.body.tenantId);
    const id = z.string().min(1).parse(req.body.id);
    const next = z.string().min(1).parse(req.body.next);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${tk.error}</pre>`);

    const store:any = args.store;
    const fn =
      store.setStatus ||
      store.updateStatus ||
      store.setWorkItemStatus ||
      store.updateWorkItemStatus ||
      null;

    if (!fn) {
      return res.status(501).send(`<pre>status_update_not_supported_by_store</pre>`);
    }

    await fn.call(store, tenantId, id, next, "ui");
    return res.redirect(302, `/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(String(req.body.k||""))}`);
  });

  r.get("/export.csv", async (req, res) => {
    const tenantId = z.string().min(1).parse(req.query.tenantId);
    const tk = requireTenantKey(req as any, tenantId, args.tenants);
    if (!tk.ok) return res.status(tk.status).send(`<pre>${tk.error}</pre>`);

    const items = await args.store.listWorkItems(tenantId, { limit: 1000, offset: 0 });

    const header = [
      "id","tenantId","source","sender","subject","category","priority","status","slaSeconds","dueAt","createdAt","updatedAt"
    ].join(",");

    const lines = items.map((it:any)=>[
      csvEscape(it.id),
      csvEscape(it.tenantId),
      csvEscape(it.source),
      csvEscape(it.sender),
      csvEscape(it.subject),
      csvEscape(it.category),
      csvEscape(it.priority),
      csvEscape(it.status),
      csvEscape(it.slaSeconds),
      csvEscape(it.dueAt),
      csvEscape(it.createdAt),
      csvEscape(it.updatedAt),
    ].join(","));

    const csv = [header, ...lines].join("\n");

    res.setHeader("Content-Type","text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.end(csv);
  });

  return r;
}
TS

echo "==> [4] Patch server.ts to mount UI v6 once (no duplicates)"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p,"utf8");

// remove any previous ui imports
s = s.replaceAll(/import\s+\{\s*makeUiRoutes\s*\}\s+from\s+"\.\/api\/ui\.js";\s*\n/g, "");
s = s.replaceAll(/import\s+\{\s*makeUiRoutes\s*\}\s+from\s+"\.\/api\/ui_v6\.js";\s*\n/g, "");

// ensure correct import exists once
if (!s.includes('from "./api/ui_v6.js"')) {
  s = s.replace(/import\s+express\s+from\s+"express";\s*\n/, m => m + 'import { makeUiRoutes } from "./api/ui_v6.js";\n');
}

// remove any old app.use("/ui"... ) lines
s = s.replaceAll(/app\.use\(\s*["']\/ui["'][\s\S]*?\);\s*\n/g, "");

// mount /ui once near the end (before listen)
if (!s.includes('app.use("/ui", makeUiRoutes')) {
  s = s.replace(/app\.listen\(/, `app.use("/ui", makeUiRoutes({ store, tenants, publicBaseUrl: process.env.PUBLIC_BASE_URL }));\n\napp.listen(`);
}

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE

echo "==> [5] Typecheck"
pnpm -s lint:types

echo "==> [6] Add smoke script to validate UI + export returns 200"
cat > scripts/smoke-ui.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ENV_FILE="${ENV_FILE:-.env.local}"

ADMIN_KEY="$(grep -E '^ADMIN_KEY=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r' | xargs || true)"
[ -n "${ADMIN_KEY:-}" ] || { echo "missing ADMIN_KEY in $ENV_FILE"; exit 1; }

echo "==> create tenant"
OUT="$(curl -sS -X POST "$BASE_URL/api/admin/tenants/create" -H "x-admin-key: $ADMIN_KEY" -H "Content-Type: application/json" -d '{}')"
echo "$OUT"

TENANT_ID="$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);process.stdout.write(o.tenantId)})')"
TENANT_KEY="$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);process.stdout.write(o.tenantKey)})')"

echo "==> export should be 200"
code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY")"
echo "http=$code"
[ "$code" = "200" ] || { echo "❌ export not 200"; exit 1; }

echo "==> tickets should be 200"
code2="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY")"
echo "http=$code2"
[ "$code2" = "200" ] || { echo "❌ tickets not 200"; exit 1; }

echo "✅ smoke ui ok"
echo "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
SH2
chmod +x scripts/smoke-ui.sh

echo "==> [7] Commit (optional)"
git add tsconfig.json src/api/tenant-key.ts src/api/ui_v6.ts src/server.ts scripts/smoke-ui.sh 2>/dev/null || true
git commit -m "feat(phase2): UI v2 + key gate accepts ?k= + export 200 + smoke" >/dev/null 2>&1 || true

echo
echo "✅ Phase 2 installed."
echo "Now:"
echo "  1) Restart: pnpm dev"
echo "  2) Smoke:   BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  3) Get link: BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
