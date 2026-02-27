#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase31 OneShot (/ui/setup + Zapier pack + smoke) @ $ROOT"

# ---------- backup ----------
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase31_${TS}"
mkdir -p "$BAK"
cp -R src scripts "$BAK/" 2>/dev/null || true
echo "✅ backup -> $BAK"

# ---------- ensure dirs ----------
mkdir -p src/ui scripts dist

# ---------- write setup route ----------
cat > src/ui/setup_route.ts <<'TS'
import type { Express, Request, Response } from "express";
import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";

function esc(s: string) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function getBaseUrl(req: Request) {
  const proto = (req.headers["x-forwarded-proto"] as string) || req.protocol || "http";
  const host = (req.headers["x-forwarded-host"] as string) || req.get("host") || "127.0.0.1";
  return `${proto}://${host}`;
}

function mustTenant(req: Request) {
  const tenantId = String((req.query.tenantId ?? req.query.tid ?? "") as string);
  const k = String((req.query.k ?? req.query.key ?? "") as string);
  if (!tenantId || !k) return { ok: false as const, status: 401, tenantId, k, error: "missing_tenant_key" };
  const ok = verifyTenantKeyLocal(tenantId, k);
  if (!ok) return { ok: false as const, status: 401, tenantId, k, error: "invalid_tenant_key" };
  return { ok: true as const, status: 200, tenantId, k };
}

export function mountSetup(app: Express) {
  app.get("/ui/setup", (req: Request, res: Response) => {
    const auth = mustTenant(req);
    if (!auth.ok) {
      return res.status(auth.status).type("text/html").send(`<!doctype html>
<html><head><meta charset="utf-8"><title>Setup — Unauthorized</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:#05070c;color:#e5e7eb}
.wrap{max-width:980px;margin:48px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.08);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:22px;font-weight:800;margin:0 0 8px}
.muted{color:#9ca3af;font-size:13px}
pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.08);padding:12px;border-radius:12px}
a{color:#93c5fd}
</style></head>
<body><div class="wrap"><div class="card">
  <div class="h">Setup يحتاج مفتاح عميل</div>
  <div class="muted">افتح من رابط /ui/admin ثم ارجع هنا بنفس tenantId و k.</div>
  <pre>${esc(auth.error)}</pre>
  <div class="muted">Try: <a href="/ui/admin?admin=YOUR_ADMIN_KEY">/ui/admin</a></div>
</div></div></body></html>`);
    }

    const base = getBaseUrl(req);
    const webhookUrl = `${base}/api/webhook/intake?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`;
    const ticketsUrl = `${base}/ui/tickets?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`;
    const exportUrl = `${base}/ui/export.csv?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`;
    const evidenceUrl = `${base}/ui/evidence.zip?tenantId=${encodeURIComponent(auth.tenantId)}&k=${encodeURIComponent(auth.k)}`;

    const sample = {
      source: "zapier",
      form: "typeform|meta|calendly",
      lead: {
        name: "Jane Doe",
        email: "jane@example.com",
        phone: "+33...",
        company: "Acme",
        message: "Need help with ads",
      },
      meta: {
        utm_source: "facebook",
        utm_campaign: "jan-ads",
        page: "landing-1",
      },
      raw: { any: "original fields ok" }
    };

    res.status(200).type("text/html").send(`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Setup — Zapier</title>
<style>
:root{color-scheme:dark}
body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
.wrap{max-width:1180px;margin:56px auto;padding:0 18px}
.card{border:1px solid rgba(255,255,255,.08);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
.h{font-size:26px;font-weight:900;margin:0 0 6px}
.muted{color:#9ca3af;font-size:13px}
.grid{display:grid;grid-template-columns:1fr;gap:14px}
@media(min-width:920px){.grid{grid-template-columns:1.15fr .85fr}}
.btn{display:inline-block;padding:10px 14px;border-radius:12px;border:1px solid rgba(255,255,255,.10);background:rgba(0,0,0,.25);color:#e5e7eb;text-decoration:none;font-weight:800}
.btn:hover{border-color:rgba(255,255,255,.18);background:rgba(0,0,0,.34)}
.btn.primary{background:rgba(34,197,94,.16);border-color:rgba(34,197,94,.30)}
.btn.primary:hover{background:rgba(34,197,94,.22)}
.kbd{font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,"Liberation Mono",monospace;font-size:12px;padding:3px 8px;border-radius:10px;border:1px solid rgba(255,255,255,.10);background:rgba(0,0,0,.30)}
pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.08);padding:12px;border-radius:12px}
ol{margin:8px 0 0 18px}
li{margin:8px 0}
hr{border:0;border-top:1px solid rgba(255,255,255,.08);margin:14px 0}
.small{font-size:12px;color:#9ca3af}
</style></head>
<body>
<div class="wrap">
  <div class="card">
    <div class="h">Zapier Setup</div>
    <div class="muted">حوّل أي Lead من Meta/Typeform/Calendly → Ticket منظم + dedupe + CSV + Evidence ZIP.</div>
    <hr />
    <div class="grid">
      <div class="card" style="padding:16px">
        <div style="font-weight:900;margin-bottom:6px">1) Zapier — Webhooks by Zapier → <span class="kbd">POST</span></div>
        <ol>
          <li>في Zapier اختر: <span class="kbd">Webhooks by Zapier</span> → <span class="kbd">POST</span></li>
          <li>ضع URL التالي:</li>
        </ol>
        <pre id="wh">${esc(webhookUrl)}</pre>
        <div style="display:flex;gap:10px;flex-wrap:wrap;margin-top:8px">
          <a class="btn primary" href="${esc(webhookUrl)}" target="_blank" rel="noreferrer">Open Webhook URL</a>
          <button class="btn" onclick="navigator.clipboard.writeText(document.getElementById('wh').innerText)">Copy Webhook URL</button>
        </div>
        <div class="small" style="margin-top:10px">
          Headers: <span class="kbd">Content-Type: application/json</span>
        </div>
        <hr />
        <div style="font-weight:900;margin-bottom:6px">2) Body (JSON)</div>
        <pre id="js">${esc(JSON.stringify(sample, null, 2))}</pre>
        <div style="display:flex;gap:10px;flex-wrap:wrap;margin-top:8px">
          <button class="btn" onclick="navigator.clipboard.writeText(document.getElementById('js').innerText)">Copy Sample JSON</button>
        </div>
      </div>

      <div class="card" style="padding:16px">
        <div style="font-weight:900;margin-bottom:6px">Verify</div>
        <div class="muted">بعد Test في Zapier، افتح الروابط:</div>
        <div style="display:flex;gap:10px;flex-wrap:wrap;margin-top:10px">
          <a class="btn primary" href="${esc(ticketsUrl)}">Tickets</a>
          <a class="btn" href="${esc(exportUrl)}">Export CSV</a>
          <a class="btn" href="${esc(evidenceUrl)}">Evidence ZIP</a>
        </div>
        <hr />
        <div class="muted">Tenant:</div>
        <pre>${esc(auth.tenantId)}\n${esc(auth.k)}</pre>
        <div class="small">لا تشارك المفتاح مع أي طرف غير موثوق.</div>
      </div>
    </div>
  </div>
</div>
</body></html>`);
  });
}
TS
echo "✅ wrote src/ui/setup_route.ts"

# ---------- patch server.ts to mount /ui/setup (non-breaking) ----------
node <<'NODE'
const fs = require("fs");
const path = "src/server.ts";
let s = fs.readFileSync(path, "utf8");

// 1) ensure import
if (!s.includes('from "./ui/setup_route.js"')) {
  // place near other ui imports if possible
  const lines = s.split("\n");
  let idx = lines.findIndex(l => l.includes('from "./ui/routes.js"'));
  if (idx === -1) idx = lines.findIndex(l => l.includes('from "./ui"'));
  if (idx === -1) idx = 0;
  lines.splice(idx + 1, 0, 'import { mountSetup } from "./ui/setup_route.js";');
  s = lines.join("\n");
}

// 2) ensure mountSetup(app) is called after app is created and before listen
if (!s.includes("mountSetup(")) {
  // insert after mountUi(...) if exists, else after app creation
  const insertAfter = [
    /mountUi\s*\([^;]*\);\s*/m,
    /const\s+app\s*=\s*express\(\);\s*/m,
    /app\s*=\s*express\(\);\s*/m
  ];
  let inserted = false;
  for (const re of insertAfter) {
    const m = s.match(re);
    if (m) {
      const at = m.index + m[0].length;
      s = s.slice(0, at) + "\n  // Phase31: client setup page (Zapier)\n  mountSetup(app as any);\n" + s.slice(at);
      inserted = true;
      break;
    }
  }
  if (!inserted) {
    // fallback: append near bottom before listen
    const listenRe = /app\.listen\([\s\S]*?\);\s*/m;
    const m2 = s.match(listenRe);
    if (m2) {
      const at = m2.index;
      s = s.slice(0, at) + "\n// Phase31: client setup page (Zapier)\nmountSetup(app as any);\n\n" + s.slice(at);
    } else {
      s += "\n\n// Phase31: client setup page (Zapier)\nmountSetup(app as any);\n";
    }
  }
}

fs.writeFileSync(path, s);
console.log("✅ patched src/server.ts (mountSetup)");
NODE

# ---------- write Zapier pack generator ----------
cat > scripts/zapier-pack.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-}"
OUTDIR="${OUTDIR:-dist/intake-guardian-agent/zapier_pack}"

if [ -z "$TENANT_KEY" ]; then
  echo "❌ missing TENANT_KEY. Provide TENANT_KEY=... (from /ui/admin Location k=...)" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

WEBHOOK_URL="${BASE_URL}/api/webhook/intake?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
SETUP_URL="${BASE_URL}/ui/setup?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
TICKETS_URL="${BASE_URL}/ui/tickets?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
EXPORT_URL="${BASE_URL}/ui/export.csv?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
EVIDENCE_URL="${BASE_URL}/ui/evidence.zip?tenantId=${TENANT_ID}&k=${TENANT_KEY}"

cat > "$OUTDIR/webhook.url.txt" <<EOF
$WEBHOOK_URL
EOF

cat > "$OUTDIR/payload.sample.json" <<'JSON'
{
  "source": "zapier",
  "form": "typeform|meta|calendly",
  "lead": {
    "name": "Jane Doe",
    "email": "jane@example.com",
    "phone": "+33...",
    "company": "Acme",
    "message": "Need help with ads"
  },
  "meta": {
    "utm_source": "facebook",
    "utm_campaign": "jan-ads",
    "page": "landing-1"
  },
  "raw": { "any": "original fields ok" }
}
JSON

cat > "$OUTDIR/field-mapping.csv" <<'CSV'
source,field,path,notes
meta,name,lead.name,Lead full name
meta,email,lead.email,Lead email
meta,phone,lead.phone,Lead phone
meta,company,lead.company,Optional
meta,message,lead.message,Optional
typeform,name,lead.name,Answer mapping
typeform,email,lead.email,Answer mapping
calendly,name,lead.name,Invitee name
calendly,email,lead.email,Invitee email
calendly,phone,lead.phone,Custom question
CSV

cat > "$OUTDIR/ZAPIER_SETUP.md" <<EOF
# Zapier Setup — Agency Webhook Intake Tool

## 1) Create Zap
- Trigger: (Meta Leads / Typeform / Calendly / etc.)
- Action: **Webhooks by Zapier** → **POST**

## 2) POST URL
\`\`\`
$WEBHOOK_URL
\`\`\`

## 3) Headers
- Content-Type: application/json

## 4) Body (JSON)
Use this as a base and map fields from your trigger:
- see: payload.sample.json

## 5) Verify
- Setup page:
  $SETUP_URL
- Tickets:
  $TICKETS_URL
- Export CSV:
  $EXPORT_URL
- Evidence ZIP:
  $EVIDENCE_URL

## 6) Troubleshooting
- 401 invalid_tenant_key → wrong tenantId/k
- 201 created:false → dedupe hit (same lead already exists)
EOF

cat > "$OUTDIR/TROUBLESHOOTING.md" <<'EOF'
# Troubleshooting

## 401 invalid_tenant_key
- Get a fresh link from /ui/admin and re-copy tenantId + k.

## 404 Cannot POST /api/webhook/intake
- Server not restarted or mountWebhook not active.

## 201 created:false
- Dedupe is working. Same payload / dedupeKey already exists.

## UI links
- Always include: tenantId + k
EOF

echo "✅ Zapier pack generated:"
echo "  $OUTDIR"
ls -la "$OUTDIR" | sed -n '1,40p'
BASH
chmod +x scripts/zapier-pack.sh
echo "✅ wrote scripts/zapier-pack.sh"

# ---------- write smoke-phase31 ----------
cat > scripts/smoke-phase31.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
curl -s "$BASE_URL/health" >/dev/null || fail "health not ok"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden"

echo "==> [2] /ui/admin redirect (302) + capture Location"
[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r')"
code="$(echo "$hdr" | head -n 1 | awk '{print $2}')"
[ "$code" = "302" ] || { echo "$hdr" | sed -n '1,25p'; fail "admin not 302"; }
loc="$(echo "$hdr" | awk -F': ' 'tolower($1)=="location"{print $2}' | head -n 1)"
[ -n "${loc:-}" ] || { echo "$hdr" | sed -n '1,25p'; fail "no Location header from /ui/admin"; }
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

[ -n "$TENANT_ID" ] || fail "could not parse tenantId from Location"
[ -n "$TENANT_KEY" ] || fail "could not parse k from Location"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

echo "==> [3] /ui/setup should be 200"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY")"
echo "status=$s3"
[ "$s3" = "200" ] || fail "setup not 200"

echo "==> [4] Generate Zapier Pack (dist)"
BASE_URL="$BASE_URL" TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" ./scripts/zapier-pack.sh >/dev/null
[ -f "dist/intake-guardian-agent/zapier_pack/ZAPIER_SETUP.md" ] || fail "zapier pack missing"
echo "✅ zapier pack ok"

echo
echo "✅ Phase31 smoke OK"
echo "Setup:"
echo "  $BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
echo "Zapier pack:"
echo "  dist/intake-guardian-agent/zapier_pack"
BASH
chmod +x scripts/smoke-phase31.sh
echo "✅ wrote scripts/smoke-phase31.sh"

# ---------- optional: hook into release-pack if exists ----------
if [ -f "scripts/release-pack.sh" ] && ! grep -q "zapier-pack.sh" scripts/release-pack.sh; then
  cat >> scripts/release-pack.sh <<'APPEND'

# ---- Phase31: Zapier Template Pack (best effort) ----
if [ -n "${TENANT_KEY:-}" ] && [ -n "${TENANT_ID:-}" ] && [ -n "${BASE_URL:-}" ]; then
  echo "==> Zapier Template Pack"
  BASE_URL="$BASE_URL" TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" ./scripts/zapier-pack.sh || true
else
  echo "==> Zapier Template Pack (skipped: set BASE_URL + TENANT_ID + TENANT_KEY)"
fi
APPEND
  chmod +x scripts/release-pack.sh
  echo "✅ patched scripts/release-pack.sh (adds zapier pack if env provided)"
fi

# ---------- typecheck (best effort) ----------
if pnpm -s lint:types >/dev/null 2>&1; then
  echo "==> Typecheck"
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase31 installed."
echo "Now:"
echo "  1) restart: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke:   ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase31.sh"
echo
