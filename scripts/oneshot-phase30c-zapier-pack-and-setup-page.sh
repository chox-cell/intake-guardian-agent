#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase30c OneShot (Zapier Pack + /ui/setup + smoke-phase30) @ $ROOT"

[ -d "src" ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
[ -d "scripts" ] || { echo "ERROR: run inside repo root (scripts missing)"; exit 1; }

TS="$(date -u +%Y%m%d_%H%M%S)"
BAK="__bak_phase30c_${TS}"
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
let j;
try { j = JSON.parse(fs.readFileSync(p,"utf8")); } catch { process.exit(0); }
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
for (const x of ["__bak_*","__bak_phase*","__bak_phase30c_*"]) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j,null,2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE
fi

echo "==> Detect intake endpoint path from scripts/smoke-webhook.sh (best effort)"
INTAKE_PATH="/api/webhook/intake"
if [ -f "scripts/smoke-webhook.sh" ]; then
  INTAKE_PATH="$(node - <<'NODE'
const fs = require("node:fs");
const s = fs.readFileSync("scripts/smoke-webhook.sh","utf8");
const m = s.match(/\/api\/[a-zA-Z0-9_\/-]*intake/g);
if (!m || !m.length) { console.log("/api/webhook/intake"); process.exit(0); }
console.log(m[m.length-1]);
NODE
)"
fi
echo "INTAKE_PATH=${INTAKE_PATH}"

echo "==> Write docs/zapier pack"
mkdir -p docs/zapier docs/zapier/payload-examples

cat > docs/zapier/README.md <<EOF
# Zapier Template Pack — Intake Guardian Agent

هدف الباك:
أي Lead يجي من Meta/Typeform/Calendly/Website عبر Zapier → يتحول Ticket منظم (dedupe) + Export CSV + Evidence ZIP.

## الروابط
- Admin Autolink:
  /ui/admin?adminKey=YOUR_ADMIN_KEY
- Tickets:
  /ui/tickets?tenantId=...&k=...
- Export:
  /ui/export.csv?tenantId=...&k=...
- Evidence ZIP:
  /ui/evidence.zip?tenantId=...&k=...
- Setup page (this):
  /ui/setup?tenantId=...&k=...

## Zapier Action (POST)
- URL: \${BASE_URL}${INTAKE_PATH}
- Method: POST
- Headers:
  - Content-Type: application/json

Payload example:
See: docs/zapier/payload-examples/intake-lead.json
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
# Zapier Template Spec

Trigger:
- Typeform/Calendly/Meta Lead Ads/Website form

Action:
- Webhooks by Zapier → POST
- URL: \${BASE_URL}${INTAKE_PATH}
- Body: JSON (see payload examples)

Expected:
- HTTP 201
- Ticket appears in /ui/tickets
- Export CSV includes the ticket
- Evidence ZIP contains ticket snapshot
EOF

echo "==> Add /ui/setup route in a robust place (server.ts), non-breaking"
# We'll mount /ui/setup directly in server.ts after app creation.
# This avoids fragile parsing of src/ui/routes.ts and any mountUi naming issues.

node - <<'NODE'
const fs = require("node:fs");

const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

if (s.includes('app.get("/ui/setup"')) {
  console.log("OK: /ui/setup already present in src/server.ts, skipping");
  process.exit(0);
}

const markerCandidates = [
  "mountUi(",
  "app.listen",
  "server.listen",
];

let idx = -1;
for (const m of markerCandidates) {
  const i = s.indexOf(m);
  if (i !== -1) { idx = i; break; }
}
if (idx === -1) {
  console.error("ERROR: could not find insertion marker in src/server.ts");
  process.exit(1);
}

const block = `
/**
 * Phase30c: /ui/setup (Zapier instructions)
 * - public instruction page (no secrets)
 * - if tenantId + k present, shows direct links
 */
app.get("/ui/setup", (req, res) => {
  const tenantId = String((req.query as any).tenantId || "");
  const k = String((req.query as any).k || "");
  const proto = String((req.headers["x-forwarded-proto"] as any) || ((req.socket as any).encrypted ? "https" : "http"));
  const host = String((req.headers["x-forwarded-host"] as any) || req.headers.host || "localhost");
  const baseUrl = \`\${proto}://\${host}\`;

  const safe = (x: string) =>
    (x || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");

  const qs =
    tenantId && k
      ? \`?tenantId=\${encodeURIComponent(tenantId)}&k=\${encodeURIComponent(k)}\`
      : "";

  const intakePath = ${JSON.stringify(process.env.INTAKE_PATH || "")} || ${JSON.stringify(process.env.PHASE30C_INTAKE_PATH || "")};
  const defaultIntake = ${JSON.stringify("")};
  const webhook = intakePath || ${JSON.stringify("")};

  const html = \`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Setup — Intake Guardian</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
  .wrap{max-width:980px;margin:40px auto;padding:0 18px}
  .card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
  .h{font-size:22px;font-weight:800;margin:0 0 6px}
  .muted{color:#9ca3af;font-size:13px}
  pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.10);padding:12px;border-radius:12px}
  a{color:#22d3ee;text-decoration:none}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
  .pill{border:1px solid rgba(255,255,255,.12);background:rgba(0,0,0,.20);border-radius:999px;padding:6px 10px;font-size:12px}
  code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="h">Zapier Setup</div>
      <div class="muted">Turn leads → deduped tickets → export CSV + evidence ZIP.</div>

      <div class="row">
        <div class="pill">baseUrl: <b>\${safe(baseUrl)}</b></div>
        <div class="pill">tenantId: <b>\${safe(tenantId || "—")}</b></div>
        <div class="pill">k: <b>\${safe(k ? (k.slice(0,10)+"…") : "—")}</b></div>
      </div>

      <div class="muted" style="margin-top:14px">Admin autolink:</div>
      <pre><code>\${safe(baseUrl)}/ui/admin?adminKey=YOUR_ADMIN_KEY</code></pre>

      <div class="muted" style="margin-top:12px">If you already have tenantId+k:</div>
      <pre><code>Tickets:
\${safe(baseUrl)}/ui/tickets\${qs}

Export CSV:
\${safe(baseUrl)}/ui/export.csv\${qs}

Evidence ZIP:
\${safe(baseUrl)}/ui/evidence.zip\${qs}</code></pre>

      <div class="muted" style="margin-top:12px">Zapier Action (POST):</div>
      <pre><code>URL: \${safe(baseUrl)}${process.env.INTAKE_PATH || "/api/webhook/intake"}
Method: POST
Headers:
  Content-Type: application/json

Body example:
{
  "source":"zapier",
  "type":"lead",
  "lead":{"fullName":"Jane Doe","email":"jane@example.com"}
}</code></pre>

      <div class="muted" style="margin-top:10px">
        Docs folder: <code>docs/zapier</code>
      </div>
    </div>
  </div>
</body>
</html>\`;

  res.setHeader("Content-Type", "text/html; charset=utf-8");
  return res.status(200).send(html);
});

`;

s = s.slice(0, idx) + block + s.slice(idx);
fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (added /ui/setup)");
NODE

echo "==> Write smoke-phase30.sh"
cat > scripts/smoke-phase30.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $1"; exit 1; }

[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY missing"

echo "==> [0] health"
curl -sS "${BASE_URL}/health" >/dev/null || fail "health not reachable"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ui" || true)"
echo "status=$s1"
[ "$s1" = "404" ] || echo "WARN: expected 404 on /ui"

echo "==> [2] /ui/admin redirect (302 expected) + capture Location"
hdr="$(mktemp)"
curl -sS -D "$hdr" -o /dev/null "${BASE_URL}/ui/admin?adminKey=${ADMIN_KEY}" || true
loc="$(grep -i '^Location:' "$hdr" | head -n1 | sed 's/\r$//' | sed 's/Location: //I')"
rm -f "$hdr"
[ -n "$loc" ] || fail "no Location header from /ui/admin"
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"
[ -n "$TENANT_ID" ] || fail "empty TENANT_ID"
[ -n "$TENANT_KEY" ] || fail "empty TENANT_KEY"

echo "==> [3] /ui/setup should be 200"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ui/setup?tenantId=${TENANT_ID}&k=${TENANT_KEY}" || true)"
echo "status=$s3"
[ "$s3" = "200" ] || fail "/ui/setup not 200"

echo "==> [4] tickets should be 200"
s4="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ui/tickets?tenantId=${TENANT_ID}&k=${TENANT_KEY}" || true)"
echo "status=$s4"
[ "$s4" = "200" ] || fail "tickets not 200"

echo "==> [5] export.csv should be 200"
s5="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ui/export.csv?tenantId=${TENANT_ID}&k=${TENANT_KEY}" || true)"
echo "status=$s5"
[ "$s5" = "200" ] || fail "export.csv not 200"

echo "==> [6] evidence.zip should be 200"
s6="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ui/evidence.zip?tenantId=${TENANT_ID}&k=${TENANT_KEY}" || true)"
echo "status=$s6"
[ "$s6" = "200" ] || fail "evidence.zip not 200"

echo "==> [7] webhook intake should be 201 (smoke-webhook.sh)"
[ -f "./scripts/smoke-webhook.sh" ] || fail "missing scripts/smoke-webhook.sh"
TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" BASE_URL="$BASE_URL" ./scripts/smoke-webhook.sh

echo
echo "✅ Phase30 smoke OK"
echo "Setup UI:"
echo "  ${BASE_URL}/ui/setup?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
echo "Tickets UI:"
echo "  ${BASE_URL}/ui/tickets?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
echo "Export CSV:"
echo "  ${BASE_URL}/ui/export.csv?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
echo "Evidence ZIP:"
echo "  ${BASE_URL}/ui/evidence.zip?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
BASH
chmod +x scripts/smoke-phase30.sh
echo "✅ wrote scripts/smoke-phase30.sh"

echo "==> Typecheck (best effort)"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase30c installed."
echo "Now:"
echo "  1) restart: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke:   ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase30.sh"
echo "  3) open:    http://127.0.0.1:7090/ui/setup (or with tenantId+k)"
