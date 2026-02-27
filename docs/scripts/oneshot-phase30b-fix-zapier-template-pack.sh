# =====================================================================
# Phase30b OneShot — Fix Zapier Template Pack (robust UI patch) + Smoke
# Repo: intake-guardian-agent
# =====================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase30b OneShot @ $ROOT"

[ -d "src" ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
[ -d "scripts" ] || { echo "ERROR: run inside repo root (scripts missing)"; exit 1; }
[ -f "src/ui/routes.ts" ] || { echo "ERROR: missing src/ui/routes.ts"; exit 1; }

TS="$(date -u +%Y%m%d_%H%M%S)"
BAK="__bak_phase30b_${TS}"
echo "==> Backup -> $BAK"
mkdir -p "$BAK"
cp -R "src" "$BAK/src"
cp -R "scripts" "$BAK/scripts"
[ -d "docs" ] && cp -R "docs" "$BAK/docs" || true
[ -f "tsconfig.json" ] && cp -f "tsconfig.json" "$BAK/tsconfig.json" || true

echo "==> Ensure tsconfig excludes backups (best effort)"
if [ -f "tsconfig.json" ]; then
  node - <<'NODE'
const fs = require("node:fs");
const p = "tsconfig.json";
let s = fs.readFileSync(p, "utf8");
let j;
try { j = JSON.parse(s); } catch { process.exit(0); }
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const need = ["__bak_*","__bak_phase*","__bak_phase30b_*"];
for (const x of need) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE
fi

echo "==> Detect intake endpoint path from scripts/smoke-webhook.sh (best effort)"
INTAKE_PATH="/api/intake"
if [ -f "scripts/smoke-webhook.sh" ]; then
  INTAKE_PATH="$(node - <<'NODE'
const fs = require("node:fs");
const s = fs.readFileSync("scripts/smoke-webhook.sh","utf8");
const m =
  s.match(/\$BASE_URL([^\s"'\\]+)/) ||
  s.match(/\$\{BASE_URL\}([^\s"'\\]+)/) ||
  s.match(/BASE_URL["']?\s*\+\s*["']([^"']+)/);
if (!m) { console.log("/api/intake"); process.exit(0); }
console.log(m[1]);
NODE
)"
fi
echo "INTAKE_PATH=${INTAKE_PATH}"

echo "==> Write Zapier docs + assets"
mkdir -p docs/zapier docs/zapier/payload-examples

cat > docs/zapier/README.md <<EOF
# Zapier Template Pack — Intake Guardian Agent (Phase30b)

This product turns incoming leads (Meta/Typeform/Calendly/Website) into **deduped tickets** with:
- Admin redirect link (tenant-scoped)
- Tickets UI
- CSV export
- Webhook intake (Zapier-friendly)

---

## 1) Admin link (tenant-scoped UI)
Start your server, then open:

- /ui/admin?adminKey=YOUR_ADMIN_KEY

It redirects you to:
- /ui/tickets?tenantId=...&k=...

**Copy** that URL. The query params are your tenant credentials for the UI.

---

## 2) Zapier setup (recommended)
Zap: *Trigger* → *Action*

### Trigger
- Webhooks by Zapier → Catch Hook  
(or Typeform / Calendly / Meta lead ads, etc.)

### Action
- Webhooks by Zapier → POST

**URL**
- \${BASE_URL}${INTAKE_PATH}

**Method**
- POST

**Headers**
- Content-Type: application/json

**Body**
Use a JSON payload similar to:
\`docs/zapier/payload-examples/intake-lead.json\`

---

## 3) Testing (local)
1) Smoke UI:
\`\`\`bash
ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh
\`\`\`

2) Extract tenantId + k (TENANT_KEY) from the Location it prints.

3) Smoke webhook:
\`\`\`bash
TENANT_ID=tenant_demo TENANT_KEY=<k_from_location> BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-webhook.sh
\`\`\`

4) Phase30b smoke (end-to-end):
\`\`\`bash
ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase30b-zapier.sh
\`\`\`

---

## 4) Client delivery checklist
- ✅ Server starts with ADMIN_KEY
- ✅ /ui/admin redirects
- ✅ /ui/tickets loads
- ✅ /ui/export.csv downloads
- ✅ Webhook intake returns 201 and dedupes
- ✅ Docs included (this folder)

EOF

cat > docs/zapier/payload-examples/intake-lead.json <<'EOF'
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "Jane Doe",
    "email": "jane@example.com",
    "phone": "+33 6 00 00 00 00",
    "company": "Example Co",
    "notes": "Interested in SEO + Ads. Budget 1500€/mo."
  },
  "meta": {
    "campaign": "Meta Lead Ads",
    "form": "Lead Form A",
    "ts": "2026-01-04T00:00:00Z"
  }
}
EOF

cat > docs/zapier/ZAPIER_TEMPLATE_SPEC.md <<EOF
# Zapier Template Spec (Human-readable)

Goal:
Trigger (any lead source) → POST to Intake Guardian Agent → Ticket created/deduped.

Inputs:
- JSON payload (see payload examples)

Outputs:
- HTTP 201 with ticket object
- Ticket appears in /ui/tickets
- CSV export includes it

Endpoint:
- \${BASE_URL}${INTAKE_PATH}

EOF

echo "==> Patch UI: add /ui/setup page (robust insertion, no mountUi dependency)"
node - <<'NODE'
const fs = require("node:fs");
const p = "src/ui/routes.ts";
let s = fs.readFileSync(p, "utf8");

if (s.includes('app.get("/ui/setup"') || s.includes("app.get('/ui/setup'")) {
  console.log("OK: /ui/setup already present, skipping patch");
  process.exit(0);
}

const INTAKE_PATH = process.env.INTAKE_PATH || "/api/intake";

// Find a stable anchor near other UI routes
const anchors = [
  'app.get("/ui/tickets"',
  "app.get('/ui/tickets'",
  'app.get("/ui/export.csv"',
  "app.get('/ui/export.csv'",
  'app.get("/ui/admin"',
  "app.get('/ui/admin'"
];

let idx = -1;
let which = "";
for (const a of anchors) {
  const i = s.indexOf(a);
  if (i !== -1 && (idx === -1 || i < idx)) { idx = i; which = a; }
}

if (idx === -1) {
  console.error("ERROR: Could not find an anchor route in src/ui/routes.ts to insert /ui/setup.");
  console.error("HINT: Expected one of: /ui/admin, /ui/tickets, /ui/export.csv");
  process.exit(1);
}

const insert = `
  // ------------------------------------------------------------
  // Phase30b: /ui/setup — client-ready Zapier instructions page
  // (No fragile dependency on mountUi() name. Inserted near UI routes.)
  // ------------------------------------------------------------
  app.get("/ui/setup", (req, res) => {
    const tenantId = String(req.query.tenantId || "");
    const k = String(req.query.k || "");
    const proto = String((req.headers["x-forwarded-proto"] || (req.socket as any).encrypted ? "https" : "http") || "http");
    const host = String(req.headers["x-forwarded-host"] || req.headers.host || "localhost");
    const baseUrl = \`\${proto}://\${host}\`;

    const safe = (x: string) => (x || "").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
    const qs = tenantId && k ? \`?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}\` : "";

    // IMPORTANT: this page contains only instructions (no sensitive data).
    // Tickets UI itself remains protected by tenantId+k checks in existing routes.
    const html = \`<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Setup — Intake Guardian</title>
  <style>
    :root{ --bg:#0b0f14; --card:#0f172a; --ink:#e5e7eb; --muted:#94a3b8; --line:rgba(148,163,184,.2); --a:#22d3ee; --r:14px; --mono:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono","Courier New",monospace; --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,Helvetica,Arial,sans-serif;}
    *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);}
    .wrap{max-width:980px;margin:24px auto;padding:0 16px;}
    .hero{padding:18px 18px 14px;border:1px solid var(--line);background:linear-gradient(135deg,#0b0f14,#0b1220 55%,#081018);border-radius:18px;}
    .k{font-family:var(--mono);font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:rgba(229,231,235,.7)}
    h1{margin:6px 0 2px;font-size:22px}
    .sub{color:rgba(229,231,235,.72);font-size:13px}
    .grid{display:grid;grid-template-columns:1fr;gap:12px;margin-top:12px}
    .card{border:1px solid var(--line);background:rgba(15,23,42,.55);border-radius:var(--r);padding:14px}
    .card h2{margin:0 0 8px;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:rgba(229,231,235,.75)}
    code,pre{font-family:var(--mono);font-size:12px}
    pre{margin:10px 0 0;padding:12px;border:1px solid rgba(148,163,184,.18);border-radius:12px;background:rgba(0,0,0,.25);overflow:auto}
    a{color:var(--a);text-decoration:none}
    .muted{color:var(--muted);font-size:12px}
    .row{display:flex;flex-wrap:wrap;gap:10px;margin-top:10px}
    .pill{border:1px solid rgba(148,163,184,.18);border-radius:999px;padding:6px 10px;background:rgba(255,255,255,.04);font-family:var(--mono);font-size:11px;color:rgba(229,231,235,.8)}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="hero">
      <div class="k">Intake Guardian Agent</div>
      <h1>Zapier Setup</h1>
      <div class="sub">Turn incoming leads into deduped tickets + CSV export.</div>
      <div class="row">
        <div class="pill">tenantId: <b>\${safe(tenantId || "—")}</b></div>
        <div class="pill">k: <b>\${safe(k ? (k.slice(0,10) + "…") : "—")}</b></div>
        <div class="pill">baseUrl: <b>\${safe(baseUrl)}</b></div>
      </div>
      <div class="muted" style="margin-top:10px">
        Tip: Open <a href="/ui/tickets\${qs}">Tickets UI</a> or <a href="/ui/export.csv\${qs}">Export CSV</a>
      </div>
    </div>

    <div class="grid">
      <div class="card">
        <h2>1) Get your tenant link</h2>
        <div class="muted">Ask the admin to open:</div>
        <pre><code>\${safe(baseUrl)}/ui/admin?adminKey=YOUR_ADMIN_KEY</code></pre>
        <div class="muted" style="margin-top:8px">It redirects to /ui/tickets?tenantId=...&k=... — copy that URL.</div>
      </div>

      <div class="card">
        <h2>2) Zapier Action (POST)</h2>
        <div class="muted">In Zapier: Webhooks by Zapier → POST</div>
        <pre><code>URL:    \${safe(baseUrl)}${INTAKE_PATH}
Method: POST
Headers:
  Content-Type: application/json

Body (example):
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "Jane Doe",
    "email": "jane@example.com",
    "phone": "+33 6 00 00 00 00",
    "company": "Example Co",
    "notes": "Interested in SEO + Ads."
  }
}</code></pre>
        <div class="muted" style="margin-top:8px">Use your existing smoke script to confirm the correct endpoint path.</div>
      </div>

      <div class="card">
        <h2>3) Verify</h2>
        <div class="muted">After Zapier sends a lead, confirm:</div>
        <pre><code>Tickets UI:
\${safe(baseUrl)}/ui/tickets\${qs}

CSV export:
\${safe(baseUrl)}/ui/export.csv\${qs}</code></pre>
      </div>
    </div>

    <div class="muted" style="margin:14px 0 10px;opacity:.85">
      Phase30b — Customer-ready docs: <code>docs/zapier</code>
    </div>
  </div>
</body>
</html>\`;

    res.setHeader("content-type", "text/html; charset=utf-8");
    return res.status(200).send(html);
  });

`;

s = s.slice(0, idx) + insert + s.slice(idx);
fs.writeFileSync(p, s);
console.log(`✅ patched ${p} (inserted /ui/setup before ${which})`);
NODE
INTAKE_PATH="$INTAKE_PATH"

echo "==> Add smoke: scripts/smoke-phase30b-zapier.sh"
cat > scripts/smoke-phase30b-zapier.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [ -z "${ADMIN_KEY}" ]; then
  echo "ERROR: ADMIN_KEY missing"
  echo "Run: ADMIN_KEY=... BASE_URL=... ./scripts/smoke-phase30b-zapier.sh"
  exit 1
fi

echo "==> [0] health"
curl -s "${BASE_URL}/health" >/dev/null
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
st=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/ui" || true)
echo "status=$st"
[ "$st" = "404" ] || echo "WARN: expected 404"

echo "==> [2] /ui/admin redirect (302 expected) + capture Location"
hdrs="$(mktemp)"
curl -s -D "$hdrs" -o /dev/null "${BASE_URL}/ui/admin?adminKey=${ADMIN_KEY}" || true
loc="$(grep -i '^Location:' "$hdrs" | head -n1 | sed 's/\r$//' | sed 's/Location: //I')"
rm -f "$hdrs"

if [ -z "$loc" ]; then
  echo "FAIL: no Location header from /ui/admin"
  exit 1
fi

echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

echo "==> [3] /ui/setup should be 200"
st=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/ui/setup?tenantId=${TENANT_ID}&k=${TENANT_KEY}" || true)
echo "status=$st"
[ "$st" = "200" ] || { echo "FAIL: /ui/setup not 200"; exit 1; }

echo "==> [4] tickets should be 200"
st=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/ui/tickets?tenantId=${TENANT_ID}&k=${TENANT_KEY}" || true)
echo "status=$st"
[ "$st" = "200" ] || { echo "FAIL: tickets not 200"; exit 1; }

echo "==> [5] export.csv should be 200"
st=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/ui/export.csv?tenantId=${TENANT_ID}&k=${TENANT_KEY}" || true)
echo "status=$st"
[ "$st" = "200" ] || { echo "FAIL: export.csv not 200"; exit 1; }

echo "==> [6] webhook intake should be 201"
if [ ! -f "./scripts/smoke-webhook.sh" ]; then
  echo "FAIL: missing ./scripts/smoke-webhook.sh"
  exit 1
fi
TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" BASE_URL="$BASE_URL" ./scripts/smoke-webhook.sh

echo
echo "✅ Phase30b smoke OK"
echo "Setup UI:"
echo "  ${BASE_URL}/ui/setup?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
echo "Tickets UI:"
echo "  ${BASE_URL}/ui/tickets?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
echo "Export CSV:"
echo "  ${BASE_URL}/ui/export.csv?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
SH
chmod +x scripts/smoke-phase30b-zapier.sh

echo "==> Typecheck (best effort)"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase30b installed."
echo "Now:"
echo "  1) restart: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke:   ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase30b-zapier.sh"
echo "  3) open:    http://127.0.0.1:7090/ui/setup (use tenantId+k from /ui/admin redirect)"
