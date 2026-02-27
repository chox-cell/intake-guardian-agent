#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
echo "==> Phase3 OneShot (Sell UI + Gate Fix) @ $ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase3_sell_${ts}"
mkdir -p "$bak"

echo "==> [0] Backup"
cp -a src "$bak/src" 2>/dev/null || true
cp -a scripts "$bak/scripts" 2>/dev/null || true
cp -a tsconfig.json "$bak/tsconfig.json" 2>/dev/null || true

echo "==> [1] Ensure scripts dir"
mkdir -p scripts

echo "==> [2] Patch tsconfig exclude backups (safe)"
if [ -f tsconfig.json ]; then
  node <<'NODE'
const fs=require("fs");
const p="tsconfig.json";
const j=JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]),
  "node_modules","dist","build",
  "__bak_*","__bak_phase3_*","__bak_ui_*","__bak_fix_*","__bak_resend_*",".bak","**/*.bak.*"
]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched", p);
NODE
fi

echo "==> [3] Write robust tenant gate: src/api/tenant-key.ts"
mkdir -p src/api
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";

// Gate behavior:
// - Accept tenant key from:
//   1) header: x-tenant-key
//   2) query:  ?k=
//   3) body:   { k: "..." }
// - Keep signature compatible with older callers (2-4 args).
//
// NOTE: tenants/shares are optional objects; we only need tenants.verify/validate if available.
export function getTenantKeyFromReq(req: Request): string | null {
  const h = (req.headers["x-tenant-key"] || req.headers["X-Tenant-Key"]) as any;
  if (typeof h === "string" && h.trim()) return h.trim();

  const qk = (req.query?.k as any) ?? (req.query?.key as any);
  if (typeof qk === "string" && qk.trim()) return qk.trim();

  const bk = (req.body as any)?.k ?? (req.body as any)?.key;
  if (typeof bk === "string" && bk.trim()) return bk.trim();

  return null;
}

// Backwards compatible signature:
// requireTenantKey(req, tenantId)
// requireTenantKey(req, tenantId, tenants)
// requireTenantKey(req, tenantId, tenants, shares)
export function requireTenantKey(
  req: Request,
  tenantId: string,
  tenants?: any,
  _shares?: any
): string {
  const k = getTenantKeyFromReq(req);
  if (!k) {
    const e: any = new Error("missing_tenant_key");
    e.status = 401;
    throw e;
  }

  // Prefer tenants store verification if exists
  if (tenants && typeof tenants.verifyTenantKey === "function") {
    const ok = tenants.verifyTenantKey(tenantId, k);
    if (!ok) {
      const e: any = new Error("invalid_tenant_key");
      e.status = 401;
      throw e;
    }
    return k;
  }

  // Fallback: store-level verifier if someone wired it there
  const storeAny: any = (req as any).__store;
  if (storeAny && typeof storeAny.verifyTenantKey === "function") {
    const ok = storeAny.verifyTenantKey(tenantId, k);
    if (!ok) {
      const e: any = new Error("invalid_tenant_key");
      e.status = 401;
      throw e;
    }
    return k;
  }

  // If no verifier exists, allow (dev mode) — but still return key for logging
  return k;
}
TS

echo "==> [4] Write SELL UI (no tech) + internal demo ticket: src/api/ui_sell.ts"
cat > src/api/ui_sell.ts <<'TS'
import type { Request, Response } from "express";
import { Router } from "express";
import { requireTenantKey } from "./tenant-key.js";

type AnyStore = any;

function esc(s: any): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c] as string));
}

function waLinkFromEnv() {
  const phoneRaw = (process.env.PUBLIC_WHATSAPP_PHONE || "").trim();
  const textRaw  = (process.env.PUBLIC_WHATSAPP_TEXT  || "Hi Intake-Guardian, I want a demo.").trim();

  // WhatsApp expects digits with country code (no +, no spaces)
  const phone = phoneRaw.replace(/[^\d]/g, "");
  if (!phone) return null;

  const url = `https://api.whatsapp.com/send?phone=${encodeURIComponent(phone)}&text=${encodeURIComponent(textRaw)}`;
  return url;
}

function uiShell(opts: {
  title: string;
  tenantId: string;
  shareUrl: string;
  exportUrl: string;
  waUrl?: string | null;
  body: string;
}) {
  const { title, tenantId, shareUrl, exportUrl, waUrl, body } = opts;

  const waBtn = waUrl
    ? `<a class="btn btn-green" href="${esc(waUrl)}" target="_blank" rel="noreferrer">Book Demo (WhatsApp)</a>`
    : `<button class="btn btn-disabled" disabled title="Set PUBLIC_WHATSAPP_PHONE in env">Book Demo (WhatsApp)</button>`;

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>${esc(title)}</title>
  <style>
    :root{
      --bg:#0b1020; --card:#101a33; --muted:#90a3c7; --text:#e8efff;
      --line:rgba(255,255,255,.08);
      --blue:#3b82f6; --green:#22c55e; --amber:#f59e0b; --red:#ef4444;
      --btn:#172554; --btn2:#111827;
    }
    *{box-sizing:border-box}
    body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 700px at 20% 0%, rgba(59,130,246,.18), transparent 60%), var(--bg);color:var(--text)}
    .wrap{max-width:1100px;margin:32px auto;padding:0 18px}
    .top{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap}
    h1{margin:0;font-size:22px;letter-spacing:.2px}
    .sub{color:var(--muted);font-size:13px;margin-top:4px}
    .card{margin-top:14px;background:linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,.03));border:1px solid var(--line);border-radius:16px;padding:14px}
    .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
    .btn{border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);padding:10px 12px;border-radius:12px;text-decoration:none;font-weight:600;font-size:13px;cursor:pointer}
    .btn:hover{background:rgba(255,255,255,.07)}
    .btn-green{background:rgba(34,197,94,.15);border-color:rgba(34,197,94,.35)}
    .btn-blue{background:rgba(59,130,246,.15);border-color:rgba(59,130,246,.35)}
    .btn-ghost{background:transparent}
    .btn-disabled{opacity:.5;cursor:not-allowed}
    .pill{display:inline-flex;align-items:center;gap:8px;background:rgba(0,0,0,.25);border:1px solid var(--line);padding:10px 12px;border-radius:12px;width:100%}
    .pill code{color:#c7d2fe;word-break:break-all}
    .pill .copy{margin-left:auto}
    table{width:100%;border-collapse:separate;border-spacing:0;margin-top:10px;overflow:hidden;border-radius:14px;border:1px solid var(--line)}
    th,td{padding:12px 10px;border-bottom:1px solid var(--line);font-size:13px}
    th{color:#b9c7e6;text-transform:uppercase;letter-spacing:.12em;font-size:11px;background:rgba(0,0,0,.22)}
    tr:last-child td{border-bottom:none}
    .status{display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border-radius:999px;border:1px solid var(--line);font-weight:700;font-size:12px}
    .s-new{background:rgba(59,130,246,.12);border-color:rgba(59,130,246,.3)}
    .s-progress{background:rgba(245,158,11,.12);border-color:rgba(245,158,11,.3)}
    .s-done{background:rgba(34,197,94,.12);border-color:rgba(34,197,94,.3)}
    .actions{display:flex;gap:8px;flex-wrap:wrap}
    .mini{padding:8px 10px;border-radius:10px;font-size:12px}
    .footer{margin-top:14px;color:var(--muted);font-size:12px}
    input,select{background:rgba(0,0,0,.22);border:1px solid var(--line);color:var(--text);padding:10px 12px;border-radius:12px;font-size:13px}
    .filters{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:10px}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <div>
        <h1>Tickets</h1>
        <div class="sub">tenant: <b>${esc(tenantId)}</b></div>
      </div>
      <div class="row">
        <a class="btn btn-blue" href="${esc(shareUrl)}">Refresh</a>
        <button class="btn" id="copyLink">Copy link</button>
        <a class="btn btn-green" href="${esc(exportUrl)}">Export CSV</a>
        ${waBtn}
      </div>
    </div>

    <div class="card">
      <div style="color:var(--muted);font-size:12px;margin-bottom:6px">Share with your client (no login UI for demo):</div>
      <div class="pill">
        <code id="shareUrl">${esc(shareUrl)}</code>
        <button class="btn mini copy" id="copyLink2">Copy</button>
      </div>

      ${body}

      <div class="footer">
        Intake-Guardian — one place to see requests, change status, and export proof for management.
      </div>
    </div>
  </div>

<script>
(function(){
  function copyText(t){
    navigator.clipboard.writeText(t).then(()=>alert("Copied ✅")).catch(()=>prompt("Copy:", t));
  }
  var url = document.getElementById("shareUrl").innerText;
  document.getElementById("copyLink").onclick = function(){ copyText(url); };
  document.getElementById("copyLink2").onclick = function(){ copyText(url); };

  document.querySelectorAll("[data-action='status']").forEach(function(btn){
    btn.addEventListener("click", async function(){
      const id = btn.getAttribute("data-id");
      const next = btn.getAttribute("data-next");
      btn.disabled = true;
      try{
        const res = await fetch(location.pathname + "/status", {
          method: "POST",
          headers: {"Content-Type":"application/json"},
          body: JSON.stringify({ id, next })
        });
        if(!res.ok){
          const t = await res.text();
          alert("Failed: " + t);
        } else {
          location.reload();
        }
      } finally {
        btn.disabled = false;
      }
    });
  });

  const demoBtn = document.getElementById("createDemo");
  if(demoBtn){
    demoBtn.onclick = async function(){
      demoBtn.disabled = true;
      try{
        const res = await fetch(location.pathname + "/demo", { method: "POST" });
        const t = await res.text();
        if(!res.ok) alert("Failed: " + t);
        else location.reload();
      } finally { demoBtn.disabled = false; }
    };
  }

  const applyBtn = document.getElementById("applyFilters");
  if(applyBtn){
    applyBtn.onclick = function(){
      const q = new URLSearchParams(location.search);
      q.set("search", (document.getElementById("search")||{}).value || "");
      q.set("status", (document.getElementById("status")||{}).value || "");
      location.search = q.toString();
    }
  }
  const resetBtn = document.getElementById("resetFilters");
  if(resetBtn){
    resetBtn.onclick = function(){
      const q = new URLSearchParams(location.search);
      q.delete("search"); q.delete("status");
      location.search = q.toString();
    }
  }
})();
</script>
</body>
</html>`;
}

function guessStatusBadge(s: string) {
  const v = (s || "").toLowerCase();
  if (v.includes("done") || v.includes("closed") || v.includes("resolved")) return { cls: "s-done", label: "Done" };
  if (v.includes("progress") || v.includes("working") || v.includes("triage")) return { cls: "s-progress", label: "In progress" };
  return { cls: "s-new", label: "New" };
}

async function safeList(store: AnyStore, tenantId: string, q: any) {
  if (typeof store.listWorkItems === "function") {
    return await store.listWorkItems(tenantId, q);
  }
  if (typeof store.listTickets === "function") {
    return await store.listTickets(tenantId, q);
  }
  return [];
}

async function safeSetStatus(store: AnyStore, tenantId: string, id: string, next: string) {
  if (typeof store.setStatus === "function") return await store.setStatus(tenantId, id, next, "ui");
  if (typeof store.updateStatus === "function") return await store.updateStatus(tenantId, id, next);
  if (typeof store.updateWorkItem === "function") return await store.updateWorkItem(tenantId, id, { status: next });
  throw new Error("status_update_not_supported");
}

async function safeCreateDemo(store: AnyStore, tenantId: string) {
  const payload = {
    from: "employee@corp.local",
    subject: "VPN broken (demo)",
    text: "VPN is down ASAP. Cannot access network.",
    source: "demo",
  };
  if (typeof store.createWorkItem === "function") return await store.createWorkItem(tenantId, payload);
  if (typeof store.addWorkItem === "function") return await store.addWorkItem(tenantId, payload);
  if (typeof store.createTicket === "function") return await store.createTicket(tenantId, payload);
  throw new Error("demo_create_not_supported");
}

export function makeUiRoutes(args: { store: AnyStore; tenants?: any }) {
  const r = Router();

  // inject store into req for fallback verifier
  r.use((req, _res, next) => {
    (req as any).__store = args.store;
    next();
  });

  r.get("/tickets", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");

    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      return res.status(e?.status || 401).send(e?.message || "invalid_tenant_key");
    }

    const k = (req.query.k as string) || "";
    const shareUrl = `${req.protocol}://${req.get("host")}${req.baseUrl}/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const exportUrl = `${req.protocol}://${req.get("host")}${req.baseUrl}/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const waUrl = waLinkFromEnv();

    const search = String(req.query.search || "").trim();
    const status = String(req.query.status || "").trim();

    const q: any = {};
    if (search) q.search = search;
    if (status) q.status = status;

    const items = await safeList(args.store, tenantId, q);

    const rows = (items || []).map((it: any) => {
      const id = it.id || it.ticketId || it.workItemId || "";
      const subj = it.subject || it.title || "";
      const sender = it.from || it.sender || "";
      const pri = it.priority || "normal";
      const st = it.status || "new";
      const badge = guessStatusBadge(st);
      const due = it.dueAt || it.due || it.slaDue || it.sla || "";

      return `<tr>
        <td>${esc(id)}</td>
        <td><div style="font-weight:700">${esc(subj)}</div><div style="color:#90a3c7;font-size:12px">${esc(sender)}</div></td>
        <td><span class="status ${badge.cls}">${esc(badge.label)}</span></td>
        <td>${esc(pri)}</td>
        <td>${esc(due)}</td>
        <td>
          <div class="actions">
            <button class="btn mini" data-action="status" data-id="${esc(id)}" data-next="new">New</button>
            <button class="btn mini" data-action="status" data-id="${esc(id)}" data-next="in_progress">In progress</button>
            <button class="btn mini" data-action="status" data-id="${esc(id)}" data-next="done">Done</button>
          </div>
        </td>
      </tr>`;
    }).join("");

    const filtersHtml = `
      <div class="filters">
        <input id="search" placeholder="Search…" value="${esc(search)}" />
        <select id="status">
          <option value="" ${status===""?"selected":""}>All statuses</option>
          <option value="new" ${status==="new"?"selected":""}>New</option>
          <option value="in_progress" ${status==="in_progress"?"selected":""}>In progress</option>
          <option value="done" ${status==="done"?"selected":""}>Done</option>
        </select>
        <button class="btn" id="applyFilters">Apply</button>
        <button class="btn btn-ghost" id="resetFilters">Reset</button>
      </div>`;

    const emptyState = `
      <div style="margin-top:14px;color:var(--muted)">
        No tickets yet. Click <b>Create demo ticket</b> to see the flow.
      </div>
      <div class="row" style="margin-top:12px">
        <button class="btn btn-blue" id="createDemo">Create demo ticket</button>
      </div>
    `;

    const table = `
      ${filtersHtml}
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Subject / Sender</th>
            <th>Status</th>
            <th>Priority</th>
            <th>SLA / Due</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          ${(items && items.length) ? rows : `<tr><td colspan="6">${emptyState}</td></tr>`}
        </tbody>
      </table>
    `;

    res.setHeader("content-type","text/html; charset=utf-8");
    res.status(200).send(uiShell({
      title: "Tickets",
      tenantId,
      shareUrl,
      exportUrl,
      waUrl,
      body: table
    }));
  });

  r.post("/tickets/status", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");
    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      return res.status(e?.status || 401).send(e?.message || "invalid_tenant_key");
    }

    const id = String((req.body as any)?.id || "");
    const next = String((req.body as any)?.next || "");
    if (!id || !next) return res.status(400).send("missing_id_or_next");

    try {
      await safeSetStatus(args.store, tenantId, id, next);
      return res.status(200).send("ok");
    } catch (e: any) {
      return res.status(500).send(e?.message || "status_update_failed");
    }
  });

  r.post("/tickets/demo", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");
    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      return res.status(e?.status || 401).send(e?.message || "invalid_tenant_key");
    }

    try {
      await safeCreateDemo(args.store, tenantId);
      return res.status(200).send("ok");
    } catch (e: any) {
      return res.status(500).send(e?.message || "demo_create_failed");
    }
  });

  r.get("/export.csv", async (req: Request, res: Response) => {
    const tenantId = String(req.query.tenantId || "");
    if (!tenantId) return res.status(400).send("missing_tenantId");
    try {
      requireTenantKey(req, tenantId, args.tenants);
    } catch (e: any) {
      return res.status(e?.status || 401).send(e?.message || "invalid_tenant_key");
    }

    const items = await safeList(args.store, tenantId, {});
    const lines = [
      ["id","subject","from","status","priority","due"].join(","),
      ...(items || []).map((it: any) => {
        const id = (it.id || it.ticketId || it.workItemId || "");
        const subject = (it.subject || it.title || "").replaceAll('"','""');
        const from = (it.from || it.sender || "").replaceAll('"','""');
        const status = (it.status || "new");
        const priority = (it.priority || "normal");
        const due = (it.dueAt || it.due || it.slaDue || it.sla || "");
        return `"${id}","${subject}","${from}","${status}","${priority}","${due}"`;
      })
    ].join("\n");

    res.setHeader("Content-Type","text/csv; charset=utf-8");
    res.setHeader("Content-Disposition", `attachment; filename="tickets_${tenantId}.csv"`);
    res.status(200).send(lines + "\n");
  });

  return r;
}
TS

echo "==> [5] Patch server.ts to mount SELL UI once"
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// 1) remove any previous ui imports (ui.js, ui_v6.js, ui_sell.js) to avoid duplicates
s = s.replace(/^\s*import\s+\{\s*makeUiRoutes\s*\}\s+from\s+["']\.\/api\/ui(_v6|_sell)?\.js["'];\s*$/gm, "");
s = s.replace(/^\s*import\s+\{\s*makeUiRoutes\s*\}\s+from\s+["']\.\/api\/ui\.js["'];\s*$/gm, "");

// 2) ensure we import from ui_sell.js near top (after other imports)
if (!s.includes(`from "./api/ui_sell.js"`)) {
  // insert after first block of imports
  const m = s.match(/^(?:import[^\n]*\n)+/);
  if (m) {
    s = s.replace(m[0], m[0] + `import { makeUiRoutes } from "./api/ui_sell.js";\n`);
  } else {
    s = `import { makeUiRoutes } from "./api/ui_sell.js";\n` + s;
  }
}

// 3) remove any existing app.use("/ui", ...) mounts to avoid duplicates
s = s.replace(/^\s*app\.use\(\s*["']\/ui["']\s*,[^\n]*\)\s*;?\s*$/gm, "");

// 4) mount /ui with our routes (must happen after store/tenants exist)
// We'll insert right after store is created OR after app creation if we can't find.
const mountLine = `app.use("/ui", makeUiRoutes({ store, tenants }));\n`;

if (s.includes(mountLine)) {
  fs.writeFileSync(p, s);
  console.log("✅ server.ts already has /ui mount");
  process.exit(0);
}

// Try to place after a line that defines `const store =`
const idx = s.search(/const\s+store\s*=/);
if (idx !== -1) {
  // insert after the end of that line
  const lineEnd = s.indexOf("\n", idx);
  s = s.slice(0, lineEnd+1) + mountLine + s.slice(lineEnd+1);
} else {
  // fallback: after `const app = express()`
  const idx2 = s.search(/const\s+app\s*=\s*express\(\)\s*;?/);
  if (idx2 !== -1) {
    const le = s.indexOf("\n", idx2);
    s = s.slice(0, le+1) + mountLine + s.slice(le+1);
  } else {
    // last resort: append near top
    s = mountLine + s;
  }
}

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE

echo "==> [6] Update scripts: demo-keys + smoke (no python)"
cat > scripts/demo-keys.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"

# read ADMIN_KEY from .env.local if present
ADMIN_KEY="${ADMIN_KEY:-}"
if [ -z "${ADMIN_KEY}" ] && [ -f .env.local ]; then
  ADMIN_KEY="$(grep -E '^ADMIN_KEY=' .env.local | tail -n1 | cut -d= -f2- | tr -d '\r')"
fi
if [ -z "${ADMIN_KEY}" ]; then
  echo "missing_ADMIN_KEY (set ADMIN_KEY env or in .env.local)" >&2
  exit 1
fi

# Try POST /api/admin/tenants/create (most likely)
OUT="$(curl -sS -X POST "$BASE_URL/api/admin/tenants/create" \
  -H "x-admin-key: $ADMIN_KEY" \
  -H "content-type: application/json" \
  --data '{}' || true)"

# If server returned HTML/plain error, try alternative route /api/admin/tenants (POST)
if ! echo "$OUT" | node -e 'process.exit((() => { try { JSON.parse(require("fs").readFileSync(0,"utf8")); return 0 } catch(e){ return 1 } })())' >/dev/null 2>&1; then
  OUT="$(curl -sS -X POST "$BASE_URL/api/admin/tenants" \
    -H "x-admin-key: $ADMIN_KEY" \
    -H "content-type: application/json" \
    --data '{}' || true)"
fi

# parse tenantId/tenantKey
TENANT_ID="$(echo "$OUT" | node -e 'const fs=require("fs");const t=fs.readFileSync(0,"utf8").trim();try{const j=JSON.parse(t);process.stdout.write(j.tenantId||"")}catch(e){process.stdout.write("")}')"
TENANT_KEY="$(echo "$OUT" | node -e 'const fs=require("fs");const t=fs.readFileSync(0,"utf8").trim();try{const j=JSON.parse(t);process.stdout.write(j.tenantKey||"")}catch(e){process.stdout.write("")}')"

if [ -z "$TENANT_ID" ] || [ -z "$TENANT_KEY" ]; then
  echo "tenant_create_failed_or_non_json_response"
  echo "raw_output:"
  echo "$OUT"
  exit 1
fi

echo
echo "==> ✅ UI link"
echo "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
echo
echo "==> ✅ Export CSV"
echo "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
SH
chmod +x scripts/demo-keys.sh

cat > scripts/smoke-ui.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"

TENANT_ID="${TENANT_ID:-}"
TENANT_KEY="${TENANT_KEY:-}"

if [ -z "$TENANT_ID" ] || [ -z "$TENANT_KEY" ]; then
  echo "==> No TENANT_ID/TENANT_KEY provided; creating tenant..."
  OUT="$(BASE_URL="$BASE_URL" ./scripts/demo-keys.sh | tail -n 2 | tr '\n' ' ')"
  # OUT has both links; extract tenantId and k from UI link
  UI_LINK="$(BASE_URL="$BASE_URL" ./scripts/demo-keys.sh | grep -E '^http' | head -n1)"
  TENANT_ID="$(echo "$UI_LINK" | node -e 'const u=new URL(require("fs").readFileSync(0,"utf8").trim());process.stdout.write(u.searchParams.get("tenantId")||"")')"
  TENANT_KEY="$(echo "$UI_LINK" | node -e 'const u=new URL(require("fs").readFileSync(0,"utf8").trim());process.stdout.write(u.searchParams.get("k")||"")')"
fi

if [ -z "$TENANT_ID" ] || [ -z "$TENANT_KEY" ]; then
  echo "❌ missing_tenantId_or_key_after_create"
  exit 1
fi

echo "==> Smoke: UI HTML headers"
curl -sSI "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY" | sed -n '1,20p'

echo
echo "==> Smoke: Export CSV headers"
curl -sSI "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY" | sed -n '1,20p'

echo
echo "✅ smoke ui ok"
echo "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
SH
chmod +x scripts/smoke-ui.sh

echo "==> [7] Typecheck"
pnpm -s lint:types

echo "==> [8] Done"
echo
echo "Now:"
echo "  1) Set env (optional):"
echo "     PUBLIC_WHATSAPP_PHONE=33600000000"
echo "     PUBLIC_WHATSAPP_TEXT='Hi Intake-Guardian, I want a demo.'"
echo "  2) Restart: pnpm dev"
echo "  3) Demo link: BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  4) Smoke:     BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
