#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${ts}"
mkdir -p "$BAK"

echo "==> One-shot B3: Founder /ui/admin/provision (one-click) + easy Agency kit"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

backup() {
  local p="$1"
  if [ -f "$p" ]; then
    mkdir -p "$BAK/$(dirname "$p")"
    cp -v "$p" "$BAK/$p.bak" >/dev/null
  fi
}

# ---------- backups ----------
backup "src/server.ts"
backup "src/ui/routes.ts"
backup "src/api/admin-tenants.ts"

# ---------- write: API helper (additive) ----------
mkdir -p src/api

cat > src/api/admin-provision.ts <<'TS'
import type { Request, Response } from "express";
import crypto from "crypto";
import fs from "fs";
import path from "path";

type TenantRecord = {
  tenantId: string;
  k: string;
  createdAt: string;
  label?: string;
  email?: string;
};

type TenantStore = {
  tenants: TenantRecord[];
};

function baseUrlFromReq(req: Request) {
  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = (req.headers["x-forwarded-host"] as string) || req.get("host") || "127.0.0.1:7090";
  return `${proto}://${host}`;
}

function nowISO() {
  return new Date().toISOString();
}

function randId(prefix: string) {
  return `${prefix}_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}

function randKey() {
  // url-safe
  return crypto.randomBytes(24).toString("base64url");
}

function getDataDir(req: Request) {
  const anyReq = req as any;
  const dataDir = (anyReq?.app?.locals?.DATA_DIR as string) || process.env.DATA_DIR || "./data";
  return dataDir;
}

function loadStore(filePath: string): TenantStore {
  try {
    const raw = fs.readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && Array.isArray(parsed.tenants)) return parsed as TenantStore;
  } catch {}
  return { tenants: [] };
}

function saveStore(filePath: string, store: TenantStore) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(store, null, 2), "utf8");
}

function requireAdminKey(req: Request): string | null {
  const header = (req.headers["x-admin-key"] as string) || "";
  const q = (req.query.adminKey as string) || "";
  const adminKey = header || q;

  const expected = process.env.ADMIN_KEY || "";
  if (!expected) return null;
  if (!adminKey) return null;
  if (adminKey !== expected) return null;
  return adminKey;
}

export function postAdminProvision(req: Request, res: Response) {
  const ok = requireAdminKey(req);
  if (!ok) return res.status(401).json({ ok: false, error: "unauthorized" });

  const { email, label } = (req.body || {}) as { email?: string; label?: string };

  const tenantId = randId("tenant");
  const k = randKey();

  const dataDir = getDataDir(req);
  const storeFile = path.join(dataDir, "tenants", "tenants.json");

  const store = loadStore(storeFile);
  store.tenants.unshift({
    tenantId,
    k,
    createdAt: nowISO(),
    email,
    label,
  });
  saveStore(storeFile, store);

  const baseUrl = baseUrlFromReq(req);

  const qs = `tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
  const links = {
    welcome:   `${baseUrl}/ui/welcome?${qs}`,
    pilot:     `${baseUrl}/ui/pilot?${qs}`,
    decisions: `${baseUrl}/ui/decisions?${qs}`,
    tickets:   `${baseUrl}/ui/tickets?${qs}`,
    setup:     `${baseUrl}/ui/setup?${qs}`,
    csv:       `${baseUrl}/ui/export.csv?${qs}`,
    zip:       `${baseUrl}/ui/evidence.zip?${qs}`,
  };

  const webhook = {
    url: `${baseUrl}/api/webhook/intake?tenantId=${encodeURIComponent(tenantId)}`,
    headers: {
      "content-type": "application/json",
      "x-tenant-key": k,
    },
    bodyExample: {
      source: "zapier",
      type: "lead",
      lead: { fullName: "Jane Doe", email: "jane@example.com", company: "ACME" },
    },
  };

  const curl = `curl -sS -X POST "${webhook.url}" \\
  -H "content-type: application/json" \\
  -H "x-tenant-key: ${k}" \\
  --data '{"source":"demo","type":"lead","lead":{"fullName":"Demo Lead","email":"demo@x.dev","company":"DemoCo"}}'`;

  return res.status(201).json({
    ok: true,
    baseUrl,
    tenantId,
    k,
    links,
    webhook,
    curl,
  });
}
TS

# ---------- write: UI route (Founder page) ----------
mkdir -p src/ui

cat > src/ui/admin_provision_route.ts <<'TS'
import type { Request, Response } from "express";

function esc(s: string) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function uiAdminProvision(req: Request, res: Response) {
  const adminKey = (req.query.adminKey as string) || "";
  // Keep it simple: founder pastes adminKey once; we store in localStorage in the browser.
  const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Founder — Provision Workspace</title>
  <style>
    :root{color-scheme:dark;}
    body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:#05060a;color:#e9e9f2;}
    .wrap{max-width:980px;margin:0 auto;padding:28px 16px 60px;}
    .card{background:linear-gradient(180deg,rgba(255,255,255,.06),rgba(255,255,255,.03));border:1px solid rgba(255,255,255,.10);border-radius:16px;padding:16px;box-shadow:0 10px 40px rgba(0,0,0,.35);}
    h1{font-size:22px;margin:0 0 8px;}
    p{margin:8px 0;color:rgba(233,233,242,.78);line-height:1.5}
    .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}
    input,button,textarea{border-radius:12px;border:1px solid rgba(255,255,255,.12);background:rgba(0,0,0,.35);color:#e9e9f2;padding:10px 12px;font-size:14px}
    input{min-width:280px;flex:1}
    button{cursor:pointer;background:linear-gradient(180deg,rgba(122,94,255,.9),rgba(92,72,220,.8));border:1px solid rgba(160,140,255,.35)}
    button.secondary{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12)}
    .grid{display:grid;grid-template-columns:1fr;gap:12px;margin-top:14px}
    .mono{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace}
    .pill{display:inline-flex;gap:8px;align-items:center;padding:6px 10px;border-radius:999px;border:1px solid rgba(255,255,255,.10);background:rgba(255,255,255,.05);font-size:12px;color:rgba(233,233,242,.80)}
    .ok{color:#9ef0b8}
    .warn{color:#ffd48a}
    .links a{color:#c9b9ff;text-decoration:none}
    .links a:hover{text-decoration:underline}
    textarea{width:100%;min-height:120px}
    .small{font-size:12px;color:rgba(233,233,242,.65)}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <div>
          <h1>Founder Provision — One-Click Workspace</h1>
          <p class="small">Goal: create a client workspace + give the agency an invite link + webhook kit (copy/paste).</p>
        </div>
        <span class="pill"><span class="ok">●</span>Admin-only</span>
      </div>

      <div class="grid">
        <div class="row">
          <input id="adminKey" placeholder="Admin Key" value="${esc(adminKey)}" />
          <input id="label" placeholder="Label (optional) e.g. Agency A" />
          <input id="email" placeholder="Client email (optional)" />
          <button id="btn">Create Workspace</button>
          <button class="secondary" id="btnClear">Clear</button>
        </div>

        <div id="status" class="pill"><span class="warn">●</span><span>Paste admin key, then click Create.</span></div>

        <div class="grid" id="out" style="display:none">
          <div class="card" style="padding:14px">
            <div class="row" style="justify-content:space-between">
              <div class="pill"><span class="ok">●</span><span>Agency Kit (give this to client)</span></div>
              <div class="row">
                <button class="secondary" id="copyAll">Copy All</button>
                <button class="secondary" id="openPilot">Open Pilot</button>
                <button class="secondary" id="sendTest">Send Test Lead</button>
              </div>
            </div>
            <div class="grid links" style="margin-top:10px">
              <div><b>Invite (Welcome)</b>: <a id="lWelcome" target="_blank" rel="noreferrer"></a></div>
              <div><b>Pilot</b>: <a id="lPilot" target="_blank" rel="noreferrer"></a></div>
              <div><b>Tickets</b>: <a id="lTickets" target="_blank" rel="noreferrer"></a></div>
              <div><b>Decisions</b>: <a id="lDecisions" target="_blank" rel="noreferrer"></a></div>
              <div><b>Setup</b>: <a id="lSetup" target="_blank" rel="noreferrer"></a></div>
              <div><b>Export CSV</b>: <a id="lCsv" target="_blank" rel="noreferrer"></a></div>
              <div><b>Evidence ZIP</b>: <a id="lZip" target="_blank" rel="noreferrer"></a></div>
            </div>
            <div style="margin-top:12px">
              <div class="pill"><span class="ok">●</span><span>Webhook (Zapier / Form POST)</span></div>
              <pre class="mono" id="webhook" style="white-space:pre-wrap;margin:10px 0 0"></pre>
            </div>
            <div style="margin-top:12px">
              <div class="pill"><span class="ok">●</span><span>Quick test (curl)</span></div>
              <pre class="mono" id="curl" style="white-space:pre-wrap;margin:10px 0 0"></pre>
            </div>
          </div>

          <div class="card" style="padding:14px">
            <div class="pill"><span class="ok">●</span><span>Copy/Paste block</span></div>
            <textarea id="all"></textarea>
            <p class="small">This block is what you paste to the agency. It includes links + webhook headers.</p>
          </div>
        </div>
      </div>

      <p class="small" style="margin-top:14px">
        Security note: Admin key is only used to create tenants. Tenant key is used by the agency to submit leads via webhook.
      </p>
    </div>
  </div>

<script>
  const qs = new URLSearchParams(location.search);
  const adminKeyInput = document.getElementById("adminKey");
  const labelInput = document.getElementById("label");
  const emailInput = document.getElementById("email");
  const statusEl = document.getElementById("status");
  const out = document.getElementById("out");

  const state = { tenantId:"", k:"", links:null, webhook:null, curl:"" };

  const setStatus = (kind, msg) => {
    statusEl.innerHTML = '<span class="'+(kind==="ok"?"ok":"warn")+'">●</span><span>'+msg+'</span>';
    statusEl.className = "pill";
  };

  const storeKey = () => {
    try { localStorage.setItem("dc_adminKey", adminKeyInput.value.trim()); } catch {}
  };
  const loadKey = () => {
    try {
      if (!adminKeyInput.value.trim()) {
        const v = localStorage.getItem("dc_adminKey") || "";
        if (v) adminKeyInput.value = v;
      }
    } catch {}
  };
  loadKey();

  async function provision() {
    const adminKey = adminKeyInput.value.trim();
    if (!adminKey) { setStatus("warn", "Admin key is required."); return; }
    storeKey();

    setStatus("warn", "Creating workspace...");
    out.style.display = "none";

    const resp = await fetch("/api/admin/provision?adminKey="+encodeURIComponent(adminKey), {
      method: "POST",
      headers: {"content-type":"application/json"},
      body: JSON.stringify({ label: labelInput.value.trim() || undefined, email: emailInput.value.trim() || undefined })
    });

    const json = await resp.json().catch(() => ({}));
    if (!resp.ok || !json.ok) {
      setStatus("warn", "Failed: " + (json.error || ("HTTP "+resp.status)));
      return;
    }

    state.tenantId = json.tenantId;
    state.k = json.k;
    state.links = json.links;
    state.webhook = json.webhook;
    state.curl = json.curl;

    // Fill links
    const setLink = (id, url) => {
      const a = document.getElementById(id);
      a.textContent = url;
      a.href = url;
    };

    setLink("lWelcome", json.links.welcome);
    setLink("lPilot", json.links.pilot);
    setLink("lTickets", json.links.tickets);
    setLink("lDecisions", json.links.decisions);
    setLink("lSetup", json.links.setup);
    setLink("lCsv", json.links.csv);
    setLink("lZip", json.links.zip);

    document.getElementById("webhook").textContent =
      "URL: " + json.webhook.url + "\\n" +
      "Method: POST\\n" +
      "Headers:\\n" +
      "  content-type: application/json\\n" +
      "  x-tenant-key: " + json.webhook.headers["x-tenant-key"] + "\\n" +
      "\\nBody example:\\n" +
      JSON.stringify(json.webhook.bodyExample, null, 2);

    document.getElementById("curl").textContent = json.curl;

    const block =
`Decision Cover — Agency Kit

Invite (Welcome):
${json.links.welcome}

Pilot:
${json.links.pilot}

Tickets:
${json.links.tickets}

Decisions:
${json.links.decisions}

Export CSV:
${json.links.csv}

Evidence ZIP:
${json.links.zip}

Webhook (Zapier/Form POST):
URL: ${json.webhook.url}
Method: POST
Headers:
  content-type: application/json
  x-tenant-key: ${json.webhook.headers["x-tenant-key"]}

Body example:
${JSON.stringify(json.webhook.bodyExample, null, 2)}

Quick test (curl):
${json.curl}
`;
    document.getElementById("all").value = block;

    out.style.display = "block";
    setStatus("ok", "Workspace created. Copy the Agency Kit and send it to client.");
  }

  document.getElementById("btn").addEventListener("click", () => provision().catch(e => setStatus("warn", "Error: "+e.message)));
  document.getElementById("btnClear").addEventListener("click", () => { labelInput.value=""; emailInput.value=""; });

  document.getElementById("copyAll").addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(document.getElementById("all").value); setStatus("ok", "Copied Agency Kit to clipboard."); }
    catch { setStatus("warn", "Could not copy. Select and copy manually."); }
  });

  document.getElementById("openPilot").addEventListener("click", () => {
    if (!state.links) return;
    window.open(state.links.pilot, "_blank");
  });

  document.getElementById("sendTest").addEventListener("click", async () => {
    if (!state.webhook) return;
    setStatus("warn", "Sending test lead...");
    const body = { source:"demo", type:"lead", lead:{ fullName:"Demo Lead", email:"demo@x.dev", company:"DemoCo" } };
    const resp = await fetch(state.webhook.url, {
      method:"POST",
      headers:{
        "content-type":"application/json",
        "x-tenant-key": state.k
      },
      body: JSON.stringify(body)
    });
    if (resp.status === 201) setStatus("ok", "Test lead sent (201). Open Tickets.");
    else setStatus("warn", "Test lead failed: HTTP "+resp.status);
  });
</script>
</body>
</html>`;
  res.status(200).setHeader("content-type", "text/html; charset=utf-8");
  res.send(html);
}
TS

# ---------- patch: routes.ts (add /ui/admin/provision) ----------
node - <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
const src = fs.readFileSync(file, "utf8");

if (src.includes("/ui/admin/provision")) {
  console.log("OK: routes.ts already has /ui/admin/provision");
  process.exit(0);
}

function fail(msg){
  console.error("FAIL:", msg);
  process.exit(1);
}

let out = src;

// 1) ensure import
if (!out.includes("uiAdminProvision")) {
  // Try to add near other imports (top of file)
  const lines = out.split("\n");
  let insertAt = 0;
  for (let i=0;i<lines.length;i++){
    if (!lines[i].startsWith("import")) { insertAt = i; break; }
  }
  lines.splice(insertAt, 0, `import { uiAdminProvision } from "./admin_provision_route";`);
  out = lines.join("\n");
}

// 2) add route registration
// We support a few common patterns: router.get("/ui/...", handler) OR app.get("/ui/...", handler)
// We'll insert after the first occurrence of "/ui/setup" or "/ui/admin" or last /ui route.
let inserted = false;

const candidates = [
  /(\.get\(\s*["']\/ui\/setup["'][\s\S]*?\)\s*;)/m,
  /(\.get\(\s*["']\/ui\/tickets["'][\s\S]*?\)\s*;)/m,
  /(\.get\(\s*["']\/ui\/decisions["'][\s\S]*?\)\s*;)/m,
];

for (const re of candidates) {
  const m = out.match(re);
  if (m) {
    const idx = m.index + m[0].length;
    out = out.slice(0, idx) + `\n\n  // Founder: one-click tenant provisioning\n  router.get("/ui/admin/provision", uiAdminProvision);\n` + out.slice(idx);
    inserted = true;
    break;
  }
}

if (!inserted) {
  // Fallback: find "router" definition and append before return/export end.
  if (out.includes("router") && out.includes("export")) {
    out = out.replace(/(\n\s*return\s+router\s*;\s*\n)/m, `\n  // Founder: one-click tenant provisioning\n  router.get("/ui/admin/provision", uiAdminProvision);\n$1`);
    inserted = true;
  }
}

if (!inserted) {
  fail("Could not find where to insert route in src/ui/routes.ts. Open the file and add: router.get('/ui/admin/provision', uiAdminProvision)");
}

fs.writeFileSync(file, out, "utf8");
console.log("OK: patched src/ui/routes.ts (+ /ui/admin/provision)");
NODE

# ---------- patch: server.ts (mount POST /api/admin/provision) ----------
node - <<'NODE'
const fs = require("fs");
const file = "src/server.ts";
let src = fs.readFileSync(file, "utf8");

if (src.includes("/api/admin/provision")) {
  console.log("OK: server.ts already has /api/admin/provision");
  process.exit(0);
}

// ensure import
if (!src.includes("postAdminProvision")) {
  // Put near other api imports
  const lines = src.split("\n");
  let insertAt = 0;
  for (let i=0;i<lines.length;i++){
    if (!lines[i].startsWith("import")) { insertAt = i; break; }
  }
  lines.splice(insertAt, 0, `import { postAdminProvision } from "./api/admin-provision";`);
  src = lines.join("\n");
}

// insert route before listen or before any "app.listen"
let inserted = false;

// common: define routes in main() before app.listen
const listenRe = /(app\.listen\([\s\S]*?\);\s*)/m;
const m = src.match(listenRe);
if (m) {
  const idx = m.index;
  const injection =
`\n  // Admin: one-click tenant provisioning (Founder)
  app.post("/api/admin/provision", express.json({ limit: "1mb" }), postAdminProvision);
\n`;
  src = src.slice(0, idx) + injection + src.slice(idx);
  inserted = true;
}

if (!inserted) {
  console.error("FAIL: Could not locate app.listen() to insert /api/admin/provision. Add manually near other app.post routes.");
  process.exit(1);
}

fs.writeFileSync(file, src, "utf8");
console.log("OK: patched src/server.ts (+ POST /api/admin/provision)");
NODE

# ---------- ensure express.json is available (server.ts should already import express) ----------
# If server.ts doesn't use express.json, the patch still compiles because express is likely already in scope.
# If not, user will see TS error; we keep this additive/minimal.

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json

echo
echo "OK ✅ B3 applied"
echo
echo "NEXT:"
echo "  1) Start server:"
echo "     bash scripts/dev_7090.sh"
echo
echo "  2) Open Founder page (replace ADMIN_KEY):"
echo "     http://127.0.0.1:7090/ui/admin/provision?adminKey=YOUR_ADMIN_KEY"
echo
echo "Backups: $BAK"
