#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Phase30 OneShot (Zapier Template Pack + /ui/setup page + smoke)
# Repo: intake-guardian-agent
# Goal:
#  - Add Zapier-ready template spec + payload samples (real, not demo)
#  - Add a client setup page: /ui/setup?tenantId=...&k=...
#  - Add smoke-phase30.sh to verify setup page works
#  - Extend release-pack to include zapier docs/assets
# ============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say(){ echo "==> $*"; }

[ -d "src" ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
[ -d "scripts" ] || { echo "ERROR: run inside repo root (scripts missing)"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase30_${TS}"
say "Phase30 OneShot (Zapier Template Pack) @ $ROOT"
say "Backup -> $BAK"
mkdir -p "$BAK"
cp -R src scripts package.json tsconfig.json "$BAK/" 2>/dev/null || true

say "Ensure tsconfig excludes backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
if (!fs.existsSync(p)) process.exit(0);
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const need = ["__bak_*", "dist", "node_modules"];
for (const x of need) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE

say "Write Zapier docs + assets"
mkdir -p docs/zapier assets/zapier

cat > docs/zapier/README.md <<'MD'
# Intake-Guardian — Zapier Template (Agency Intake → Ticket)

## What this does (one sentence)
Any lead from Zapier (Webhooks/Typeform/Calendly/Meta) becomes a deduped Ticket in Intake-Guardian, with CSV export + Evidence ZIP.

## Requirements
- Intake-Guardian running (default local):
  - BASE_URL: `http://127.0.0.1:7090`
- Tenant link (from admin autolink):
  - `http://127.0.0.1:7090/ui/tickets?tenantId=TENANT_ID&k=TENANT_KEY`

## Endpoint (Action step in Zapier)
**POST** `${BASE_URL}/api/webhook/intake`

### Auth
Send tenant credentials in **query** (simplest for Zapier):
`${BASE_URL}/api/webhook/intake?tenantId=TENANT_ID&k=TENANT_KEY`

(Alternative: send `x-tenant-id` + `x-tenant-key` headers if you add that later.)

### Content-Type
`application/json`

## Recommended Zap (v1)
### Trigger
- Webhooks by Zapier → **Catch Hook**
(or Typeform/Calendly/Meta Lead Ads later)

### Action
- Webhooks by Zapier → **Custom Request**
  - Method: POST
  - URL: `${BASE_URL}/api/webhook/intake?tenantId=TENANT_ID&k=TENANT_KEY`
  - Data Pass-Through?: false
  - Data: use the JSON below

## Payload (stable contract)
See: `assets/zapier/payload.example.json`

## Verify
1) Open Tickets UI:
`/ui/tickets?tenantId=TENANT_ID&k=TENANT_KEY`
2) Trigger Zap once
3) Refresh UI → ticket appears (or dedupes)
4) Export:
- CSV: `/ui/export.csv?...`
- Evidence ZIP: `/ui/evidence.zip?...`

## Notes
- Dedupe uses stable hash derived from lead/email/phone + source + external id (if present).
- Ticket is stored on disk under `./data/` (no demo placeholders).
MD

cat > assets/zapier/payload.example.json <<'JSON'
{
  "source": "zapier",
  "lead": {
    "name": "Jane Doe",
    "email": "jane@example.com",
    "phone": "+33 6 00 00 00 00"
  },
  "message": "Interested in SEO + Ads audit. Budget 1500€/mo. Wants callback today.",
  "utm": {
    "campaign": "q1_agency_growth",
    "adset": "retargeting",
    "ad": "video_01"
  },
  "meta": {
    "externalId": "zap-{{zap_meta_human_now}}",
    "raw": {
      "form": "Typeform/Meta/Calendly payload goes here"
    }
  }
}
JSON

cat > assets/zapier/ZAPIER_SETUP_30SEC.txt <<'TXT'
ZAPIER (30 sec)
1) Trigger: Webhooks by Zapier → Catch Hook
2) Action: Webhooks by Zapier → Custom Request
   - POST
   - URL: http://YOUR_HOST/api/webhook/intake?tenantId=TENANT_ID&k=TENANT_KEY
   - Headers: Content-Type: application/json
   - Data: copy assets/zapier/payload.example.json and map fields from trigger
3) Test → open /ui/tickets?tenantId=TENANT_ID&k=TENANT_KEY
4) Export proof:
   - /ui/export.csv?tenantId=...&k=...
   - /ui/evidence.zip?tenantId=...&k=...
TXT

say "Patch UI: add /ui/setup page (client-ready instructions)"
node - <<'NODE'
const fs = require("fs");

const p = "src/ui/routes.ts";
if (!fs.existsSync(p)) throw new Error("missing " + p);
let s = fs.readFileSync(p, "utf8");

// find mountUi function
const m = s.match(/export function mountUi\s*\(\s*app\s*:\s*any\s*(?:,\s*args\s*:\s*any\s*)?\)\s*\{\s*/);
if (!m) throw new Error("Could not find export function mountUi(app...) in src/ui/routes.ts");

// insert route near end of mountUi before closing brace of function (best-effort)
const marker = "\n}\n";
const idx = s.lastIndexOf(marker);
if (idx < 0) throw new Error("Could not locate end of mountUi()");

const insert = `
  // -----------------------------
  // Setup page (Zapier template)
  // -----------------------------
  app.get("/ui/setup", async (req: any, res: any) => {
    const auth = await requireUiAuth(req, res);
    if (!auth) return;

    const baseUrl =
      (req.protocol && req.get("host"))
        ? \`\${req.protocol}://\${req.get("host")}\`
        : (process.env.BASE_URL || "http://127.0.0.1:7090");

    const hookUrl = \`\${baseUrl}/api/webhook/intake?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;
    const ticketsUrl = \`\${baseUrl}/ui/tickets?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;
    const csvUrl = \`\${baseUrl}/ui/export.csv?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;
    const zipUrl = \`\${baseUrl}/ui/evidence.zip?tenantId=\${encodeURIComponent(auth.tenantId)}&k=\${encodeURIComponent(auth.tenantKey)}\`;

    const payload = {
      source: "zapier",
      lead: { name: "Jane Doe", email: "jane@example.com", phone: "+33 6 00 00 00 00" },
      message: "Interested in SEO + Ads audit. Budget 1500€/mo. Wants callback today.",
      utm: { campaign: "q1_agency_growth", adset: "retargeting", ad: "video_01" },
      meta: { externalId: "zap-" + new Date().toISOString(), raw: { note: "Map your trigger fields here" } }
    };

    res.status(200).send(renderPage("Client Setup (Zapier)", \`
      <div class="card">
        <div class="h">Client Setup</div>
        <div class="muted">Use this to connect Zapier (or any webhook source) to create deduped tickets.</div>

        <h3 style="margin:14px 0 6px">1) Webhook Endpoint</h3>
        <div class="muted">Zapier Action: Webhooks → Custom Request → POST</div>
        <pre>\${escapeHtml(hookUrl)}</pre>

        <h3 style="margin:14px 0 6px">2) JSON Payload (example)</h3>
        <div class="muted">Map fields from your trigger into this structure.</div>
        <pre>\${escapeHtml(JSON.stringify(payload, null, 2))}</pre>

        <h3 style="margin:14px 0 6px">3) Where to see results</h3>
        <div class="row">
          <a class="btn primary" href="\${ticketsUrl}">Open Tickets</a>
          <a class="btn" href="\${csvUrl}">Export CSV</a>
          <a class="btn" href="\${zipUrl}">Evidence ZIP</a>
        </div>

        <div class="muted" style="margin-top:10px">
          Tip: Send the webhook URL + this page to your client. They can test in 60 seconds.
        </div>
      </div>
    \`));
  });
`;

if (!s.includes('app.get("/ui/setup"')) {
  s = s.slice(0, idx) + insert + "\n" + s.slice(idx);
  fs.writeFileSync(p, s);
  console.log("✅ patched src/ui/routes.ts (+ /ui/setup)");
} else {
  console.log("ℹ️ /ui/setup already exists; skipped");
}
NODE

say "Write scripts/smoke-phase30.sh (UI + setup + webhook)"
cat > scripts/smoke-phase30.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "FAIL: $*" >&2; exit 1; }

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

echo "==> [0] health"
curl -sS "$BASE_URL/health" >/dev/null && echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui must be hidden"

echo "==> [2] /ui/admin redirect (302 expected) + capture Location"
[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
code="$(echo "$hdr" | head -n 1 | awk '{print $2}')"
loc="$(echo "$hdr" | awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r/,""); print $2}')"
echo "status=$code"
[ "$code" = "302" ] || fail "expected 302 from /ui/admin"
[ -n "$loc" ] || fail "no Location header from /ui/admin"
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"
[ -n "$TENANT_ID" ] || fail "empty TENANT_ID"
[ -n "$TENANT_KEY" ] || fail "empty TENANT_KEY"

tickets="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
csv="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
zip="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
setup="$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> [3] tickets should be 200"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "$tickets")"
echo "status=$s3"
[ "$s3" = "200" ] || fail "tickets not 200"

echo "==> [4] export.csv should be 200"
s4="$(curl -sS -o /dev/null -w "%{http_code}" "$csv")"
echo "status=$s4"
[ "$s4" = "200" ] || fail "export.csv not 200"

echo "==> [5] evidence.zip should be 200"
s5="$(curl -sS -o /dev/null -w "%{http_code}" "$zip")"
echo "status=$s5"
[ "$s5" = "200" ] || fail "evidence.zip not 200"

echo "==> [6] setup page should be 200"
s6="$(curl -sS -o /dev/null -w "%{http_code}" "$setup")"
echo "status=$s6"
[ "$s6" = "200" ] || fail "setup not 200"

echo "==> [7] webhook intake should be 201"
payload='{"source":"zapier","lead":{"name":"Jane Doe","email":"jane@example.com","phone":"+33 6 00 00 00 00"},"message":"Smoke test lead","utm":{"campaign":"smoke"},"meta":{"externalId":"smoke-'$(date +%s)'","raw":{"note":"phase30"}}}'
s7="$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "content-type: application/json" \
  -d "$payload" \
  "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY")"
echo "status=$s7"
[ "$s7" = "201" ] || fail "webhook not 201"

echo
echo "✅ Phase30 smoke OK"
echo "Client UI:"
echo "  $tickets"
echo "Setup:"
echo "  $setup"
echo "Export CSV:"
echo "  $csv"
echo "Evidence ZIP:"
echo "  $zip"
BASH
chmod +x scripts/smoke-phase30.sh
echo "✅ wrote scripts/smoke-phase30.sh"

say "Patch release-pack.sh to include docs/zapier + assets/zapier (best-effort)"
node - <<'NODE'
const fs = require("fs");
const p = "scripts/release-pack.sh";
if (!fs.existsSync(p)) { console.log("ℹ️ scripts/release-pack.sh not found; skipping"); process.exit(0); }
let s = fs.readFileSync(p,"utf8");

// Ensure it copies docs/zapier and assets/zapier into dist assets folder (idempotent)
if (!s.includes("docs/zapier")) {
  // Try to insert near where assets are copied (common patterns)
  const needle = "mkdir -p \"$OUT/assets\"";
  if (s.includes(needle)) {
    s = s.replace(needle, needle + "\ncp -R docs/zapier \"$OUT/assets/\" 2>/dev/null || true\ncp -R assets/zapier \"$OUT/assets/\" 2>/dev/null || true");
  } else {
    // Append a safe block near end
    s += `

# ---- Phase30: include Zapier pack ----
mkdir -p "$OUT/assets" 2>/dev/null || true
cp -R docs/zapier "$OUT/assets/" 2>/dev/null || true
cp -R assets/zapier "$OUT/assets/" 2>/dev/null || true
`;
  }
  fs.writeFileSync(p, s);
  console.log("✅ patched scripts/release-pack.sh (+ zapier assets)");
} else {
  console.log("ℹ️ release-pack already includes zapier; skipped");
}
NODE

echo "==> Typecheck (best effort)"
if pnpm -s lint:types >/dev/null 2>&1; then
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase30 installed."
echo "Now:"
echo "  1) restart: ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) smoke:   ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase30.sh"
echo "  3) release: ./scripts/release-pack.sh"
echo
echo "Open setup page after smoke prints links:"
echo "  /ui/setup?tenantId=...&k=..."
