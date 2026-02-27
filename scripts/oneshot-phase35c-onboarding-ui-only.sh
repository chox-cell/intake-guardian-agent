#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase35c OneShot (UI onboarding only: clearer /ui/setup) @ $ROOT"

STAMP="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase35c_${STAMP}"
mkdir -p "$BAK"
cp -R src scripts docs package.json tsconfig.json "$BAK" 2>/dev/null || true
echo "✅ backup -> $BAK"

mkdir -p src/ui

# -------------------------
# Rewrite /ui/setup page to be client-friendly (no new backend logic)
# -------------------------
cat > src/ui/setup_route.ts <<'TS'
import type { Express, Request, Response } from "express";

function baseUrl(req: Request) {
  const xfProto = (req.headers["x-forwarded-proto"] as string) || "";
  const xfHost = (req.headers["x-forwarded-host"] as string) || "";
  const proto = xfProto || "http";
  const host = xfHost || (req.headers.host as string) || "127.0.0.1";
  return `${proto}://${host}`;
}

function esc(s: string) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export function mountSetup(app: Express) {
  app.get("/ui/setup", async (req: Request, res: Response) => {
    const tenantId = String((req.query.tenantId as string) || "");
    const k = String((req.query.k as string) || "");
    const b = baseUrl(req);

    const ok = tenantId && k;

    const tickets = `${b}/ui/tickets?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const csv = `${b}/ui/export.csv?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const zip = `${b}/ui/evidence.zip?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;

    // NOTE: keep both query styles visible to reduce client confusion
    const webhookQuery = `${b}/api/webhook/intake?tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}`;
    const webhookHeaderOnly = `${b}/api/webhook/intake`;

    const adminAuto = `${b}/ui/admin?adminKey=YOUR_ADMIN_KEY`;

    const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Setup — Intake Guardian</title>
  <style>
    :root{
      --bg:#070A10; --panel:#0C1220; --panel2:#0A0F1B; --txt:#E9EEF8; --mut:#9AA7BF;
      --line:rgba(255,255,255,.10); --chip:rgba(255,255,255,.06);
      --good:#16a34a; --warn:#f59e0b; --btn:#111a2e;
      --shadow: 0 14px 40px rgba(0,0,0,.35);
      --r:16px;
      --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      --sans: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, "Apple Color Emoji","Segoe UI Emoji";
    }
    html,body{height:100%;}
    body{
      margin:0; background: radial-gradient(1200px 700px at 20% -10%, rgba(88,118,255,.22), transparent 55%),
                          radial-gradient(900px 600px at 90% 10%, rgba(34,211,238,.16), transparent 55%),
                          radial-gradient(800px 500px at 50% 120%, rgba(34,197,94,.10), transparent 55%),
                          var(--bg);
      color:var(--txt); font-family:var(--sans);
    }
    .wrap{max-width:980px; margin:38px auto; padding:0 16px;}
    .card{
      background: linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,.02));
      border:1px solid var(--line); border-radius:22px; box-shadow: var(--shadow);
      overflow:hidden;
    }
    .head{padding:22px 22px 14px; border-bottom:1px solid var(--line);}
    h1{margin:0; font-size:28px; letter-spacing:.2px;}
    .sub{margin-top:6px; color:var(--mut); font-size:14px;}
    .chips{display:flex; flex-wrap:wrap; gap:10px; margin-top:14px;}
    .chip{background:var(--chip); border:1px solid var(--line); border-radius:999px; padding:7px 10px; font-size:13px; color:var(--mut);}
    .body{padding:18px 22px 22px;}
    .stepgrid{display:grid; grid-template-columns: 1fr; gap:12px; margin-top:10px;}
    .step{
      background: rgba(0,0,0,.18);
      border:1px solid var(--line); border-radius: var(--r);
      padding:14px 14px;
    }
    .st{display:flex; align-items:center; justify-content:space-between; gap:12px;}
    .st b{font-size:14px;}
    .st .tag{font-size:12px; color:var(--mut);}
    .mono{font-family:var(--mono); font-size:12.5px; color:#D8E3FF; white-space:nowrap; overflow:hidden; text-overflow:ellipsis;}
    .row{display:flex; gap:10px; flex-wrap:wrap; margin-top:10px;}
    .btn{
      background: var(--btn);
      border:1px solid var(--line);
      color:var(--txt);
      padding:10px 12px;
      border-radius:12px;
      font-size:13px;
      cursor:pointer;
      transition: transform .12s ease, background .12s ease;
    }
    .btn:hover{transform: translateY(-1px); background: rgba(255,255,255,.06);}
    .btn.primary{background: rgba(34,197,94,.18); border-color: rgba(34,197,94,.35);}
    .btn.secondary{background: rgba(59,130,246,.16); border-color: rgba(59,130,246,.35);}
    .btn.warn{background: rgba(245,158,11,.14); border-color: rgba(245,158,11,.32);}
    .note{color:var(--mut); font-size:13px; line-height:1.45; margin-top:8px;}
    .hr{height:1px; background: var(--line); margin:18px 0;}
    details{
      border:1px solid var(--line);
      border-radius: var(--r);
      background: rgba(0,0,0,.14);
      padding:12px 12px;
    }
    summary{cursor:pointer; color:var(--txt); font-weight:600;}
    pre{
      margin:10px 0 0;
      padding:12px;
      border-radius: 12px;
      border:1px solid var(--line);
      background: rgba(0,0,0,.25);
      overflow:auto;
      font-family:var(--mono);
      font-size:12.5px;
      color:#D8E3FF;
    }
    .footer{margin-top:14px; color:var(--mut); font-size:12px;}
    .bad{color:#FCA5A5;}
    a{color:#93C5FD; text-decoration:none;}
    a:hover{text-decoration:underline;}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="head">
        <h1>Setup</h1>
        <div class="sub">3-minute onboarding: client opens tickets → exports CSV → downloads evidence ZIP.</div>
        <div class="chips">
          <div class="chip">baseUrl: <span class="mono">${esc(b)}</span></div>
          <div class="chip">tenantId: <span class="mono">${esc(tenantId || "—")}</span></div>
          <div class="chip">k: <span class="mono">${esc(k ? (k.slice(0, 10) + "…") : "—")}</span></div>
        </div>
      </div>

      <div class="body">
        <div class="stepgrid">

          <div class="step">
            <div class="st">
              <b>Step 1 — Admin Start Link (one click)</b>
              <span class="tag">admin only</span>
            </div>
            <div class="note">Use this when you want the tool to generate the client setup link automatically.</div>
            <div class="mono">${esc(adminAuto)}</div>
          </div>

          <div class="step">
            <div class="st">
              <b>Step 2 — Client URLs (copy + share)</b>
              <span class="tag">client</span>
            </div>

            ${ok ? `
            <div class="note">Send these 3 links to the client (they don’t need the admin key):</div>

            <div class="row">
              <button class="btn secondary" onclick="copyText('${esc(tickets)}')">Copy Tickets URL</button>
              <button class="btn secondary" onclick="copyText('${esc(csv)}')">Copy Export CSV URL</button>
              <button class="btn secondary" onclick="copyText('${esc(zip)}')">Copy Evidence ZIP URL</button>
            </div>

            <div class="hr"></div>

            <div class="note"><b>Tickets</b></div>
            <div class="mono">${esc(tickets)}</div>

            <div class="note" style="margin-top:10px;"><b>Export CSV</b></div>
            <div class="mono">${esc(csv)}</div>

            <div class="note" style="margin-top:10px;"><b>Evidence ZIP</b></div>
            <div class="mono">${esc(zip)}</div>
            ` : `
            <div class="note bad">
              Missing <b>tenantId</b> or <b>k</b> in the URL.
              Use the Admin Start Link above (or add <span class="mono">?tenantId=...&k=...</span>).
            </div>
            `}
          </div>

          <div class="step">
            <div class="st">
              <b>Step 3 — Zapier (choose one of 2 templates)</b>
              <span class="tag">zapier</span>
            </div>
            <div class="note">
              Zapier → “Webhooks by Zapier” → <b>POST</b> → send JSON.
              Use either query auth (easy) or header-only endpoint (advanced).
            </div>

            <details>
              <summary>Template 01 — Lead Intake (form/meta/typeform → ticket)</summary>
              <pre>URL (easy):
${esc(webhookQuery)}

Headers:
Content-Type: application/json

Body:
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "Jane Doe",
    "email": "jane@example.com",
    "phone": "+33...",
    "company": "Acme",
    "channel": "meta",
    "message": "Interested in SEO + Ads"
  }
}</pre>
            </details>

            <div style="height:10px"></div>

            <details>
              <summary>Template 02 — Booking Intake (calendly → ticket)</summary>
              <pre>URL (easy):
${esc(webhookQuery)}

Headers:
Content-Type: application/json

Body:
{
  "source": "zapier",
  "type": "booking",
  "booking": {
    "fullName": "John Smith",
    "email": "john@example.com",
    "event": "Discovery Call",
    "whenUtc": "2026-01-05T16:00:00Z",
    "notes": "Needs e-commerce growth plan"
  }
}</pre>
            </details>

            <div class="hr"></div>

            <details>
              <summary>Advanced — Header-only endpoint (if you don’t want tenantId+k in URL)</summary>
              <pre>POST:
${esc(webhookHeaderOnly)}

Headers:
Content-Type: application/json
X-Tenant-Id: ${esc(tenantId || "YOUR_TENANT_ID")}
X-Tenant-Key: ${esc(k || "YOUR_TENANT_KEY")}

Body: (same as templates above)</pre>
              <div class="note">
                If your server currently doesn’t support these headers yet, keep using the easy query URL.
              </div>
            </details>
          </div>

        </div>

        <div class="footer">
          Tip: if the client says “I don’t get it”, send them only:
          <b>Tickets URL</b> + tell them “Download Evidence ZIP weekly”.
        </div>
      </div>
    </div>
  </div>

<script>
  async function copyText(t) {
    try {
      await navigator.clipboard.writeText(t);
      toast("Copied ✅");
    } catch (e) {
      prompt("Copy:", t);
    }
  }
  function toast(msg){
    const el = document.createElement("div");
    el.textContent = msg;
    el.style.position="fixed";
    el.style.bottom="18px";
    el.style.left="18px";
    el.style.padding="10px 12px";
    el.style.border="1px solid rgba(255,255,255,.18)";
    el.style.borderRadius="12px";
    el.style.background="rgba(0,0,0,.55)";
    el.style.color="#E9EEF8";
    el.style.fontFamily="ui-sans-serif,system-ui";
    el.style.zIndex="9999";
    document.body.appendChild(el);
    setTimeout(()=>{ el.style.opacity="0"; el.style.transition="opacity .2s ease"; }, 900);
    setTimeout(()=>{ el.remove(); }, 1200);
  }
</script>

</body>
</html>`;

    return res.status(200).type("html").send(html);
  });
}
TS

echo "✅ wrote src/ui/setup_route.ts (client-friendly onboarding UI)"

# -------------------------
# Best-effort: ensure src/server.ts imports + mounts mountSetup(app)
# (safe, additive; does nothing if already present)
# -------------------------
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
if (!fs.existsSync(p)) {
  console.log("ℹ️ src/server.ts not found, skip patch");
  process.exit(0);
}
let s = fs.readFileSync(p, "utf8");

const importLine = 'import { mountSetup } from "./ui/setup_route.js";';
if (!s.includes(importLine)) {
  // insert after first import block
  const lines = s.split("\n");
  const firstImport = lines.findIndex(l => l.startsWith("import "));
  lines.splice(Math.max(0, firstImport + 1), 0, importLine);
  s = lines.join("\n");
}

if (!s.includes("mountSetup(app)")) {
  // try to mount near other ui mounts; else near app init
  if (s.includes("mountUi(app")) {
    s = s.replace(/mountUi\(app[^)]*\);\s*\n/, m => m + "  mountSetup(app);\n");
  } else if (s.includes("const app = express()")) {
    s = s.replace("const app = express()", "const app = express();\n  mountSetup(app)");
    s = s.replace("mountSetup(app)\n", "mountSetup(app);\n");
  } else {
    s += "\n\n// UI setup\nmountSetup(app);\n";
  }
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (ensure mountSetup)");
NODE

echo
echo "✅ Phase35c installed."
echo "Now run in TWO terminals:"
echo "  (A) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  (B) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase34.sh"
echo
echo "Open (client-friendly setup):"
echo "  http://127.0.0.1:7090/ui/setup?tenantId=tenant_demo&k=YOUR_K_HERE"
echo "Or use admin redirect you already have:"
echo "  http://127.0.0.1:7090/ui/admin?admin=super_secret_admin_123"
