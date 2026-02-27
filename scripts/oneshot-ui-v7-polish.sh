#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_ui_v7/${TS}"
mkdir -p "$BAK"

echo "==> OneShot UI v7 Polish @ $ROOT"
echo "==> backups -> $BAK"

cp -a src/server.ts "$BAK/server.ts.bak" 2>/dev/null || true
cp -a src/api/ui_v6.ts "$BAK/ui_v6.ts.bak" 2>/dev/null || true
cp -a scripts/demo-keys.sh "$BAK/demo-keys.sh.bak" 2>/dev/null || true
cp -a scripts/smoke-ui.sh "$BAK/smoke-ui.sh.bak" 2>/dev/null || true

echo "==> [1] Ensure tsconfig ignores backups"
node <<'NODE'
import fs from "fs";
const p="tsconfig.json";
const s=fs.existsSync(p)?fs.readFileSync(p,"utf8"):"{}";
let j={}; try{ j=JSON.parse(s);}catch{ j={}; }
j.exclude = Array.from(new Set([...(j.exclude||[]),
  "node_modules","dist","build",
  "__bak_*","__bak_ui_*","__bak_ui_v*","__bak_phase*","__bak_fix_*","__bak_resend_*",
  "**/*.bak.*",".bak"
]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json");
NODE

echo "==> [2] Write UI v6 (polished) -> src/api/ui_v6.ts"
cat > src/api/ui_v6.ts <<'TS'
import type { Request, Response } from "express";

/**
 * UI v6 (polished)
 * - /ui/tickets : clean table, search + status filter, copy link, export, CTA
 * - /ui/export.csv : downloads CSV
 * - /ui/status : POST to update status (runtime-safe: tries multiple store methods)
 *
 * Tenant auth: uses requireTenantKey which accepts:
 * - header: x-tenant-key
 * - query:  ?k=...
 * - body:   { k: ... }
 */

type AnyStore = any;
type AnyTenants = any;

function esc(s: any) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function toCsvCell(v: any) {
  const s = String(v ?? "");
  const needs = /[,"\n]/.test(s);
  const out = s.replaceAll('"', '""');
  return needs ? `"${out}"` : out;
}

function fmtDate(iso: any) {
  if (!iso) return "—";
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return String(iso);
    return d.toISOString().replace("T", " ").replace("Z", "Z");
  } catch {
    return String(iso);
  }
}

function baseUrl(req: Request, publicBaseUrl?: string) {
  if (publicBaseUrl) return publicBaseUrl.replace(/\/+$/, "");
  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = (req.headers["x-forwarded-host"] as string) || req.get("host") || "127.0.0.1";
  return `${proto}://${host}`;
}

async function trySetStatus(store: AnyStore, tenantId: string, id: string, next: string) {
  // Try multiple known shapes (we keep it runtime-safe).
  if (typeof store?.setStatus === "function") {
    return store.setStatus(tenantId, id, next, "ui");
  }
  if (typeof store?.updateStatus === "function") {
    return store.updateStatus(tenantId, id, next, "ui");
  }
  if (typeof store?.updateWorkItem === "function") {
    return store.updateWorkItem(tenantId, id, { status: next }, "ui");
  }
  if (typeof store?.patchWorkItem === "function") {
    return store.patchWorkItem(tenantId, id, { status: next }, "ui");
  }
  throw new Error("store_status_update_not_supported");
}

export function makeUiRoutes(args: {
  store: AnyStore;
  tenants?: AnyTenants;
  publicBaseUrl?: string;
  whatsappPhone?: string;
  whatsappText?: string;
  contactEmail?: string;
}) {
  const { store } = args;

  // Lazy import to avoid type fights across refactors
  const { requireTenantKey } = require("./tenant-key.js") as any;

  return async function uiRouter(req: Request, res: Response) {
    const u = new URL(req.originalUrl, baseUrl(req, args.publicBaseUrl));
    const path = u.pathname;

    // ---- helpers
    const tenantId = (u.searchParams.get("tenantId") || "").trim();
    if (!tenantId) {
      res.status(400).send("missing_tenantId");
      return;
    }

    // Require key for all UI endpoints
    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      res.status(401).send("invalid_tenant_key");
      return;
    }

    // ---- ROUTES
    if (path === "/ui/export.csv") {
      const status = (u.searchParams.get("status") || "").trim();
      const search = (u.searchParams.get("q") || "").trim();

      const q: any = { };
      if (status) q.status = status;
      if (search) q.search = search;

      const items = await store.listWorkItems(tenantId, q);

      const header = [
        "id","subject","sender","status","priority","slaSeconds","dueAt","createdAt","category"
      ];
      const lines = [header.join(",")];

      for (const it of items || []) {
        lines.push([
          toCsvCell(it.id),
          toCsvCell(it.subject),
          toCsvCell(it.sender),
          toCsvCell(it.status),
          toCsvCell(it.priority),
          toCsvCell(it.slaSeconds),
          toCsvCell(it.dueAt),
          toCsvCell(it.createdAt),
          toCsvCell(it.category),
        ].join(","));
      }

      const csv = lines.join("\n") + "\n";
      res.setHeader("Content-Type", "text/csv; charset=utf-8");
      res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
      res.status(200).send(csv);
      return;
    }

    if (path === "/ui/status" && req.method === "POST") {
      // Body can be urlencoded or json; we only need id/next
      const id = String((req.body && (req.body.id || req.body.ticketId)) || "");
      const next = String((req.body && (req.body.next || req.body.status)) || "");
      if (!id || !next) {
        res.status(400).json({ ok: false, error: "missing_id_or_status" });
        return;
      }
      try {
        await trySetStatus(store, tenantId, id, next);
        res.status(200).json({ ok: true });
      } catch (e: any) {
        res.status(501).json({ ok: false, error: e?.message || "status_update_failed" });
      }
      return;
    }

    if (path === "/ui/tickets") {
      const status = (u.searchParams.get("status") || "").trim();
      const search = (u.searchParams.get("q") || "").trim();

      const q: any = { };
      if (status) q.status = status;
      if (search) q.search = search;

      const items = await store.listWorkItems(tenantId, q);

      const k = u.searchParams.get("k") || ""; // used only for building share link
      const uiLink = `${baseUrl(req, args.publicBaseUrl)}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
      const exportLink = `${baseUrl(req, args.publicBaseUrl)}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}${status?`&status=${encodeURIComponent(status)}`:""}${search?`&q=${encodeURIComponent(search)}`:""}`;

      const waPhone = (args.whatsappPhone || "").replace(/[^\d+]/g, "");
      const waText = args.whatsappText || "Hi Intake-Guardian, I want a demo.";
      const waLink = waPhone
        ? `https://api.whatsapp.com/send/?phone=${encodeURIComponent(waPhone)}&text=${encodeURIComponent(waText)}&type=phone_number&app_absent=0`
        : "";

      const email = args.contactEmail || "";

      const rows = (items || []).map((it: any) => {
        const st = esc(it.status);
        const pr = esc(it.priority);
        const due = fmtDate(it.dueAt);
        const subj = esc(it.subject || "(no subject)");
        const sender = esc(it.sender || "—");
        const cat = esc(it.category || "—");
        const id = esc(it.id);

        const actions = `
          <div class="actions">
            <form method="post" action="/ui/status?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">
              <input type="hidden" name="id" value="${id}">
              <button name="next" value="new" class="btn btn-ghost ${st==="new"?"is-on":""}">New</button>
              <button name="next" value="open" class="btn btn-ghost ${st==="open"?"is-on":""}">Open</button>
              <button name="next" value="done" class="btn btn-ghost ${st==="done"?"is-on":""}">Done</button>
            </form>
          </div>
        `;

        return `
          <tr>
            <td class="mono">${id}</td>
            <td>
              <div class="subject">${subj}</div>
              <div class="muted">${sender} · <span class="chip">${cat}</span></div>
            </td>
            <td><span class="pill pill-${st}">${st}</span></td>
            <td><span class="pill pill-pr">${pr}</span></td>
            <td class="mono">${due}</td>
            <td>${actions}</td>
          </tr>
        `;
      }).join("");

      const empty = `
        <div class="empty">
          <div class="empty-title">No tickets yet</div>
          <div class="empty-sub">Send an email or WhatsApp intake to create the first ticket.</div>
          <div class="empty-actions">
            <button class="btn btn-primary" onclick="alert('Tip: use the adapter endpoint to create a demo ticket.');">Create demo ticket</button>
            <a class="btn btn-ghost" href="${esc(exportLink)}">Export CSV</a>
          </div>
          <div class="code">
            <div class="muted">Quick demo (Email adapter):</div>
            <pre>curl -sS "${baseUrl(req, args.publicBaseUrl)}/api/adapters/email/sendgrid?tenantId=${esc(tenantId)}" \\
  -H "x-tenant-key: &lt;TENANT_KEY&gt;" \\
  -F 'from=employee@corp.local' \\
  -F 'subject=VPN broken (demo)' \\
  -F 'text=VPN is down ASAP.'</pre>
          </div>
        </div>
      `;

      const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Tickets · ${esc(tenantId)}</title>
  <style>
    :root{
      --bg:#070a10; --panel:#0b1220; --panel2:#0a1020;
      --line:rgba(148,163,184,.18);
      --text:#e5e7eb; --muted:#9aa7b6;
      --brand:#3b82f6; --ok:#22c55e; --warn:#f59e0b; --danger:#ef4444;
      --radius:14px;
    }
    *{box-sizing:border-box}
    body{
      margin:0; font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Arial;
      background: radial-gradient(1000px 500px at 20% 0%, rgba(59,130,246,.12), transparent 60%),
                  radial-gradient(900px 500px at 80% 20%, rgba(34,197,94,.10), transparent 55%),
                  var(--bg);
      color:var(--text);
    }
    .wrap{max-width:1100px; margin:0 auto; padding:22px 18px 60px;}
    .top{
      display:flex; align-items:flex-start; justify-content:space-between; gap:14px;
      padding:18px; border:1px solid var(--line);
      background:linear-gradient(180deg, rgba(11,18,32,.88), rgba(11,18,32,.62));
      border-radius:var(--radius);
      box-shadow:0 12px 40px rgba(0,0,0,.35);
    }
    h1{margin:0; font-size:20px; letter-spacing:.2px}
    .sub{color:var(--muted); font-size:12px; margin-top:6px}
    .btnbar{display:flex; gap:10px; flex-wrap:wrap; justify-content:flex-end}
    .btn{
      border-radius:12px; padding:10px 12px; font-weight:700;
      border:1px solid var(--line);
      background:rgba(255,255,255,.02);
      color:var(--text); cursor:pointer; text-decoration:none; display:inline-flex; align-items:center; gap:8px;
    }
    .btn:hover{border-color:rgba(148,163,184,.35)}
    .btn-primary{background:rgba(59,130,246,.18); border-color:rgba(59,130,246,.35)}
    .btn-success{background:rgba(34,197,94,.18); border-color:rgba(34,197,94,.35)}
    .btn-ghost{background:rgba(255,255,255,.01)}
    .is-on{outline:2px solid rgba(59,130,246,.35)}
    .share{
      margin-top:12px;
      padding:14px 16px;
      border:1px dashed rgba(148,163,184,.28);
      background:rgba(255,255,255,.02);
      border-radius:var(--radius);
      display:flex; gap:10px; align-items:center; justify-content:space-between; flex-wrap:wrap;
    }
    .share pre{
      margin:0; color:#cbd5e1; font-size:12px; overflow:auto; max-width:100%;
      padding:8px 10px; background:rgba(0,0,0,.25); border-radius:10px; border:1px solid var(--line);
    }
    .filters{
      margin-top:14px;
      display:flex; gap:10px; flex-wrap:wrap;
      padding:14px 16px; border:1px solid var(--line);
      background:rgba(255,255,255,.02); border-radius:var(--radius);
      align-items:center; justify-content:space-between;
    }
    .field{display:flex; gap:10px; align-items:center; flex-wrap:wrap}
    input, select{
      background:rgba(0,0,0,.22);
      border:1px solid var(--line);
      color:var(--text);
      border-radius:12px;
      padding:10px 12px;
      outline:none;
      min-width:210px;
    }
    .table{
      margin-top:14px;
      border:1px solid var(--line);
      background:rgba(255,255,255,.02);
      border-radius:var(--radius);
      overflow:hidden;
    }
    table{width:100%; border-collapse:collapse}
    th, td{padding:12px 12px; border-bottom:1px solid rgba(148,163,184,.10); vertical-align:top}
    th{font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.12em; background:rgba(0,0,0,.22)}
    tr:hover td{background:rgba(255,255,255,.02)}
    .mono{font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace; font-size:12px}
    .muted{color:var(--muted); font-size:12px}
    .subject{font-weight:800}
    .chip{
      display:inline-block; padding:2px 8px; border-radius:999px;
      border:1px solid rgba(148,163,184,.22); background:rgba(255,255,255,.02);
    }
    .pill{display:inline-flex; align-items:center; justify-content:center;
      padding:4px 10px; border-radius:999px; border:1px solid rgba(148,163,184,.22);
      font-weight:800; font-size:12px; text-transform:lowercase;
    }
    .pill-new{background:rgba(59,130,246,.14); border-color:rgba(59,130,246,.30)}
    .pill-open{background:rgba(245,158,11,.14); border-color:rgba(245,158,11,.28)}
    .pill-done{background:rgba(34,197,94,.14); border-color:rgba(34,197,94,.28)}
    .pill-pr{background:rgba(148,163,184,.08)}
    .actions form{display:flex; gap:8px; flex-wrap:wrap}
    .empty{padding:26px 18px}
    .empty-title{font-size:16px; font-weight:900}
    .empty-sub{margin-top:6px; color:var(--muted)}
    .empty-actions{margin-top:14px; display:flex; gap:10px; flex-wrap:wrap}
    .code{margin-top:14px}
    pre{white-space:pre; overflow:auto}
    .footer{
      margin-top:16px;
      color:var(--muted);
      font-size:12px;
      text-align:left;
    }
    @media (max-width: 820px){
      .btnbar{justify-content:flex-start}
      input, select{min-width:160px}
      th:nth-child(1), td:nth-child(1){display:none}
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <div>
        <h1>Tickets</h1>
        <div class="sub">tenantId: <span class="mono">${esc(tenantId)}</span> · total: <span class="mono">${esc((items||[]).length)}</span></div>
      </div>
      <div class="btnbar">
        <a class="btn btn-primary" href="${esc(uiLink)}">Refresh</a>
        <button class="btn" onclick="copyText('${esc(uiLink)}')">Copy UI link</button>
        <a class="btn btn-success" href="${esc(exportLink)}">Export CSV</a>
        <button class="btn btn-ghost" onclick="changeTenant()">Change tenant</button>
      </div>
    </div>

    <div class="share">
      <div class="muted">Share this with the client:</div>
      <pre id="share">${esc(uiLink)}</pre>
    </div>

    <div class="filters">
      <div class="field">
        <form method="get" action="/ui/tickets">
          <input type="hidden" name="tenantId" value="${esc(tenantId)}"/>
          <input type="hidden" name="k" value="${esc(k)}"/>
          <input name="q" value="${esc(search)}" placeholder="Search subject/sender..." />
          <select name="status">
            <option value="" ${status===""?"selected":""}>All statuses</option>
            <option value="new" ${status==="new"?"selected":""}>new</option>
            <option value="open" ${status==="open"?"selected":""}>open</option>
            <option value="done" ${status==="done"?"selected":""}>done</option>
          </select>
          <button class="btn btn-primary" type="submit">Apply</button>
          <a class="btn btn-ghost" href="/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}">Reset</a>
        </form>
      </div>
      <div class="field">
        ${waLink ? `<a class="btn btn-success" href="${esc(waLink)}" target="_blank" rel="noreferrer">Book demo on WhatsApp</a>` : ``}
        ${email ? `<a class="btn" href="mailto:${esc(email)}?subject=${encodeURIComponent("Intake-Guardian demo")}" target="_blank">Contact by Email</a>` : ``}
      </div>
    </div>

    <div class="table">
      <table>
        <thead>
          <tr>
            <th style="width:22%">Id</th>
            <th>Subject / Sender</th>
            <th style="width:10%">Status</th>
            <th style="width:10%">Priority</th>
            <th style="width:16%">SLA / Due</th>
            <th style="width:22%">Actions</th>
          </tr>
        </thead>
        <tbody>
          ${rows || `<tr><td colspan="6">${empty}</td></tr>`}
        </tbody>
      </table>
    </div>

    <div class="footer">
      Intake-Guardian · proof UI (sellable MVP) · export & status in one place.
    </div>
  </div>

  <script>
    function copyText(t){
      navigator.clipboard.writeText(t).then(()=>toast("Copied ✅")).catch(()=>prompt("Copy this:", t));
    }
    function toast(msg){
      const d=document.createElement('div');
      d.textContent=msg;
      d.style.position='fixed';
      d.style.bottom='18px';
      d.style.left='50%';
      d.style.transform='translateX(-50%)';
      d.style.padding='10px 14px';
      d.style.border='1px solid rgba(148,163,184,.25)';
      d.style.background='rgba(0,0,0,.55)';
      d.style.color='#e5e7eb';
      d.style.borderRadius='12px';
      d.style.fontWeight='800';
      d.style.zIndex='9999';
      document.body.appendChild(d);
      setTimeout(()=>d.remove(), 1400);
    }
    function changeTenant(){
      const t = prompt("Tenant ID:");
      const k = prompt("Tenant key:");
      if(!t || !k) return;
      location.href = "/ui/tickets?tenantId="+encodeURIComponent(t)+"&k="+encodeURIComponent(k);
    }
  </script>
</body>
</html>`;

      res.setHeader("Content-Type", "text/html; charset=utf-8");
      res.status(200).send(html);
      return;
    }

    // fallback
    res.status(404).send("not_found");
  };
}
TS

echo "==> [3] Patch src/server.ts to mount UI v6 once (no duplicates)"
node <<'NODE'
import fs from "fs";
const p="src/server.ts";
let s=fs.readFileSync(p,"utf8");

// remove old ui imports if any
s = s.replace(/^\s*import\s+\{\s*makeUiRoutes\s*\}\s+from\s+"\.\/*api\/ui\.js";\s*\n/mg, "");
s = s.replace(/^\s*import\s+\{\s*makeUiRoutes\s*\}\s+from\s+"\.\/*api\/ui_v6\.js";\s*\n/mg, "");

// ensure import exists once
if (!s.includes('from "./api/ui_v6.js"')) {
  s = s.replace(/import .*?\n/, (m)=> m + 'import { makeUiRoutes } from "./api/ui_v6.js";\n');
}

// ensure mount exists once
// we insert/replace a block that mounts /ui
const mountRe = /app\.use\(\s*["']\/ui["']\s*,[\s\S]*?\);\s*\n/m;
const mountBlock = `app.use("/ui", makeUiRoutes({
  store,
  tenants,
  publicBaseUrl: process.env.PUBLIC_BASE_URL,
  whatsappPhone: process.env.WHATSAPP_DEMO_PHONE,
  whatsappText: process.env.WHATSAPP_DEMO_TEXT || "Hi Intake-Guardian, I want a demo.",
  contactEmail: process.env.CONTACT_EMAIL || process.env.RESEND_FROM
} as any));\n`;

if (mountRe.test(s)) {
  s = s.replace(mountRe, mountBlock);
} else {
  // try to place after app is created (best-effort)
  const idx = s.indexOf("const app");
  if (idx !== -1) {
    const after = s.indexOf("\n", idx);
    s = s.slice(0, after+1) + "\n" + mountBlock + "\n" + s.slice(after+1);
  } else {
    s += "\n" + mountBlock + "\n";
  }
}

fs.writeFileSync(p,s);
console.log("✅ Patched src/server.ts");
NODE

echo "==> [4] Fix scripts/demo-keys.sh to use python3 (fallback safe)"
cat > scripts/demo-keys.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"

# Pull admin key from .env.local or env
ADMIN_KEY="${ADMIN_KEY:-}"
if [ -z "${ADMIN_KEY}" ] && [ -f .env.local ]; then
  ADMIN_KEY="$(grep -E '^ADMIN_KEY=' .env.local | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
fi

if [ -z "${ADMIN_KEY}" ]; then
  echo "❌ ADMIN_KEY missing. Put it in .env.local (ADMIN_KEY=...)" >&2
  exit 1
fi

echo "==> Create tenant (admin)"
OUT="$(curl -sS "$BASE_URL/api/admin/tenants/create" -H "x-admin-key: $ADMIN_KEY" || true)"
echo "$OUT"

# Parse with python3 if available, otherwise just print links below using grep
TENANT_ID=""
TENANT_KEY=""

if command -v python3 >/dev/null 2>&1; then
  TENANT_ID="$(echo "$OUT" | python3 - <<'PY'
import json,sys
o=json.load(sys.stdin)
print(o.get("tenantId",""))
PY
)"
  TENANT_KEY="$(echo "$OUT" | python3 - <<'PY'
import json,sys
o=json.load(sys.stdin)
print(o.get("tenantKey",""))
PY
)"
else
  TENANT_ID="$(echo "$OUT" | sed -n 's/.*"tenantId":"\([^"]*\)".*/\1/p')"
  TENANT_KEY="$(echo "$OUT" | sed -n 's/.*"tenantKey":"\([^"]*\)".*/\1/p')"
fi

echo
echo "==> ✅ UI link"
echo "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo
echo "==> ✅ Export CSV"
echo "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo
echo "==> Open in browser"
open "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY" >/dev/null 2>&1 || true
SH2
chmod +x scripts/demo-keys.sh

echo "==> [5] Write scripts/smoke-ui.sh"
cat > scripts/smoke-ui.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"

# create tenant
OUT="$(BASE_URL="$BASE_URL" ./scripts/demo-keys.sh | tail -n +1 | cat)"
TENANT_ID="$(echo "$OUT" | grep -Eo 'tenantId=[^& ]+' | head -n1 | cut -d= -f2)"
TENANT_KEY="$(echo "$OUT" | grep -Eo 'k=[^& ]+' | head -n1 | cut -d= -f2)"

echo "==> smoke: GET /ui/tickets"
code1="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY")"
[ "$code1" = "200" ] || { echo "❌ tickets not 200 (got $code1)"; exit 1; }

echo "==> smoke: HEAD /ui/export.csv"
code2="$(curl -sS -I -o /dev/null -w '%{http_code}' "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY")"
[ "$code2" = "200" ] || { echo "❌ export not 200 (got $code2)"; exit 1; }

echo "✅ smoke ui ok"
echo "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
SH2
chmod +x scripts/smoke-ui.sh

echo "==> [6] Typecheck"
pnpm -s lint:types

echo
echo "✅ UI v7 installed."
echo "Now:"
echo "  1) pnpm dev"
echo "  2) BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  3) BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
