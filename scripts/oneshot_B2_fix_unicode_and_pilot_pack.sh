#!/usr/bin/env bash
set -euo pipefail

cd ~/Projects/intake-guardian-agent

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> One-shot B2: fix unicode patch + fix A2Z leads auth + add Pilot Sales Pack UI"
echo "==> ROOT: $(pwd)"
echo "==> BAK : $BAK"

# -----------------------------
# 0) backups
# -----------------------------
for f in \
  src/ui/routes.ts \
  src/ui/routes.js \
  src/ui/admin_provision_route.ts \
  src/ui/start_route.ts \
  src/ui/start_route.js \
  scripts/client_experience_a2z.sh \
  scripts/demo_leads.jsonl
do
  if [ -f "$f" ]; then
    mkdir -p "$BAK/$(dirname "$f")"
    cp -v "$f" "$BAK/$f.bak"
  fi
done

mkdir -p tools

# -----------------------------
# 1) Node patcher: mountAdminProvisionUI + mountPilotSalesPack inside mountUi(app)
#    (No perl, no unicode issues)
# -----------------------------
cat > tools/patch-ui-routes.mjs <<'EOF'
import fs from "node:fs";
import path from "node:path";

function fail(msg) {
  console.error("FAIL:", msg);
  process.exit(1);
}

const candidates = ["src/ui/routes.ts", "src/ui/routes.js"];
const file = candidates.find((p) => fs.existsSync(p));
if (!file) fail("cannot find src/ui/routes.ts|js");

let s = fs.readFileSync(file, "utf8");

// 1) ensure imports (TS) or requires (JS)
const isTS = file.endsWith(".ts");

if (isTS) {
  if (!s.includes("mountAdminProvisionUI")) {
    // keep ASCII only
    s = s.replace(
      /(^import[^\n]*\n)/m,
      `$1import { mountAdminProvisionUI } from "./admin_provision_route.js";\n`
    );
  }
  if (!s.includes("mountPilotSalesPack")) {
    s = s.replace(
      /(^import[^\n]*\n)/m,
      `$1import { mountPilotSalesPack } from "./pilot_sales_pack_route.js";\n`
    );
  }
} else {
  if (!s.includes("admin_provision_route")) {
    s = s.replace(
      /(^const[^\n]*\n)/m,
      `$1const { mountAdminProvisionUI } = require("./admin_provision_route");\n`
    );
  }
  if (!s.includes("pilot_sales_pack_route")) {
    s = s.replace(
      /(^const[^\n]*\n)/m,
      `$1const { mountPilotSalesPack } = require("./pilot_sales_pack_route");\n`
    );
  }
}

// 2) ensure calls inside mountUi(app)
const m = s.match(/function\s+mountUi\s*\(\s*app[^\)]*\)\s*\{([\s\S]*?)\n\}/m);
if (!m) fail("cannot locate function mountUi(app) { ... } in " + file);

if (!s.includes("mountAdminProvisionUI(")) {
  s = s.replace(
    /function\s+mountUi\s*\(\s*app[^\)]*\)\s*\{([\s\S]*?)\n\}/m,
    (all, body) =>
      all.replace(
        body,
        `${body}\n\n  // Admin (Founder) - Provision workspace + invite link\n  mountAdminProvisionUI(app as any);\n`
      )
  );
}

if (!s.includes("mountPilotSalesPack(")) {
  s = s.replace(
    /function\s+mountUi\s*\(\s*app[^\)]*\)\s*\{([\s\S]*?)\n\}/m,
    (all, body) =>
      all.replace(
        body,
        `${body}\n\n  // Pilot Sales Pack - 60s demo page\n  mountPilotSalesPack(app as any);\n`
      )
  );
}

fs.writeFileSync(file, s, "utf8");
console.log("OK: patched", file);
EOF

node tools/patch-ui-routes.mjs

# -----------------------------
# 2) Add Pilot Sales Pack route: src/ui/pilot_sales_pack_route.ts
# -----------------------------
mkdir -p src/ui
cat > src/ui/pilot_sales_pack_route.ts <<'EOF'
import type { Express, Request, Response } from "express";

function safeHtml(x: string) {
  return (x || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function getBaseUrl(req: Request) {
  const proto = String((req.headers["x-forwarded-proto"] as any) || ((req.socket as any).encrypted ? "https" : "http"));
  const host = String((req.headers["x-forwarded-host"] as any) || req.headers.host || "localhost");
  return `${proto}://${host}`;
}

export function mountPilotSalesPack(app: Express) {
  app.get("/ui/pilot", (req, res) => {
    const baseUrl = getBaseUrl(req);
    const tenantId = String((req.query as any).tenantId || "");
    const k = String((req.query as any).k || "");

    const has = Boolean(tenantId && k);
    const qs = has ? `tenantId=${encodeURIComponent(tenantId)}&k=${encodeURIComponent(k)}` : "";

    const links = has
      ? {
          welcome: `${baseUrl}/ui/welcome?${qs}`,
          decisions: `${baseUrl}/ui/decisions?${qs}`,
          tickets: `${baseUrl}/ui/tickets?${qs}`,
          setup: `${baseUrl}/ui/setup?${qs}`,
          csv: `${baseUrl}/ui/export.csv?${qs}`,
          zip: `${baseUrl}/ui/evidence.zip?${qs}`,
          webhook: `${baseUrl}/api/webhook/intake?tenantId=${encodeURIComponent(tenantId)}`,
        }
      : null;

    const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Pilot Sales Pack</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(1200px 800px at 30% 20%, #0b1633 0%, #05070c 65%);color:#e5e7eb}
  .wrap{max-width:980px;margin:40px auto;padding:0 18px}
  .card{border:1px solid rgba(255,255,255,.10);background:rgba(17,24,39,.55);border-radius:18px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.35)}
  .h{font-size:22px;font-weight:800;margin:0 0 6px}
  .muted{color:#9ca3af;font-size:13px}
  .row{display:flex;gap:10px;flex-wrap:wrap;margin-top:10px}
  .btn{display:inline-flex;align-items:center;justify-content:center;border:1px solid rgba(255,255,255,.12);background:rgba(99,102,241,.25);color:#fff;border-radius:12px;padding:10px 12px;font-weight:700;cursor:pointer;text-decoration:none}
  .btn.secondary{background:rgba(0,0,0,.25)}
  pre{white-space:pre-wrap;word-break:break-word;background:rgba(0,0,0,.35);border:1px solid rgba(255,255,255,.10);padding:12px;border-radius:12px}
  code{font-family:ui-monospace,Menlo,Monaco,Consolas,monospace;font-size:12px}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  @media (max-width:900px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="h">Pilot Sales Pack</div>
      <div class="muted">60 seconds: intake -> tickets -> export proof (CSV + ZIP).</div>

      <div class="row">
        <div class="muted">baseUrl: <b>${safeHtml(baseUrl)}</b></div>
        <div class="muted">tenantId: <b>${safeHtml(tenantId || "missing")}</b></div>
        <div class="muted">k: <b>${safeHtml(k ? (k.slice(0,10)+"...") : "missing")}</b></div>
      </div>

      ${has ? `
      <div class="row" style="margin-top:14px">
        <a class="btn" href="${safeHtml(links!.tickets)}">Open Tickets</a>
        <a class="btn secondary" href="${safeHtml(links!.decisions)}">Open Decisions</a>
        <a class="btn secondary" href="${safeHtml(links!.setup)}">Open Setup</a>
        <a class="btn secondary" href="${safeHtml(links!.csv)}">Download CSV</a>
        <a class="btn secondary" href="${safeHtml(links!.zip)}">Download Evidence ZIP</a>
      </div>

      <div class="muted" style="margin-top:14px">Zapier / Form POST (copy-paste):</div>
      <pre><code>URL: ${safeHtml(links!.webhook)}
Method: POST
Headers:
  Content-Type: application/json
  x-tenant-key: ${safeHtml(k)}

Body example:
{
  "source":"zapier",
  "type":"lead",
  "lead":{"fullName":"Jane Doe","email":"jane@example.com","company":"ACME"}
}</code></pre>

      <div class="muted" style="margin-top:10px">Quick test (one lead):</div>
      <pre><code>curl -sS -X POST "${safeHtml(links!.webhook)}" \\
  -H "content-type: application/json" \\
  -H "x-tenant-key: ${safeHtml(k)}" \\
  --data '{"source":"demo","type":"lead","lead":{"fullName":"Demo Lead","email":"demo@x.dev","company":"DemoCo"}}'</code></pre>
      ` : `
      <div class="muted" style="margin-top:14px">
        Missing tenantId + k. Open /ui/welcome (from email link) then come back with those query params.
      </div>
      `}
    </div>
  </div>
</body>
</html>`;

    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.status(200).send(html);
  });
}
EOF

# -----------------------------
# 3) Fix client_experience_a2z.sh (open url quoting + leads auth)
# -----------------------------
cat > scripts/client_experience_a2z.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
EMAIL="${EMAIL:-test+agency@local.dev}"
DATA_DIR="${DATA_DIR:-./data}"
LEADS="${LEADS:-./scripts/demo_leads.jsonl}"

echo "==> Client Experience A2Z"
echo "==> BASE_URL  = $BASE_URL"
echo "==> EMAIL     = $EMAIL"
echo "==> DATA_DIR  = $DATA_DIR"
echo "==> LEADS     = $LEADS"
echo

code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: /health expected 200, got $code" >&2
  exit 1
fi
echo "OK: /health => 200"
echo

echo "==> 1) Request login link"
code="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/api/auth/request-link" \
  -H "content-type: application/json" \
  --data "{\"email\":\"$EMAIL\"}" || true)"
echo "request-link => HTTP $code"
if [ "$code" != "200" ]; then
  echo "FAIL: request-link expected 200" >&2
  exit 1
fi
echo

echo "==> 2) Read latest outbox email + extract verify URL"
latest="$(ls -1t "$DATA_DIR/outbox"/mail_*.txt 2>/dev/null | head -n 1 || true)"
if [ -z "${latest:-}" ]; then
  echo "FAIL: no outbox mail found (need dev outbox)" >&2
  exit 1
fi
echo "OK: latest mail => $latest"

verify="$(rg -n "http://|https://" "$latest" | head -n 1 | sed -E 's/.*(https?:\/\/[^ ]+).*/\1/' || true)"
if [ -z "${verify:-}" ]; then
  echo "FAIL: could not extract verify URL from outbox" >&2
  exit 1
fi
echo "OK: verify URL extracted (hidden)"
echo

echo "==> 3) Verify (expect redirect to /ui/welcome)"
redir="$(curl -sS -D - -o /dev/null "$verify" | rg -n "^location:" | tail -n 1 | sed -E 's/^location:\s*//I' | tr -d '\r' || true)"
if [ -z "${redir:-}" ]; then
  echo "FAIL: no redirect location from verify" >&2
  exit 1
fi
echo "OK: redirect =>  $redir"

# normalize to absolute URL
if [[ "$redir" == /* ]]; then
  redir="$BASE_URL$redir"
fi
echo "OK: welcome =>  $redir"
echo

echo "==> 4) Opening Welcome UI"
if command -v open >/dev/null 2>&1; then
  open "$redir" || true
else
  echo "Open manually: $redir"
fi

tenantId="$(python - <<PY
import sys, urllib.parse
u = urllib.parse.urlparse("$redir")
q = urllib.parse.parse_qs(u.query)
print((q.get("tenantId") or [""])[0])
PY
)"
k="$(python - <<PY
import sys, urllib.parse
u = urllib.parse.urlparse("$redir")
q = urllib.parse.parse_qs(u.query)
print((q.get("k") or [""])[0])
PY
)"

if [ -z "${tenantId:-}" ] || [ -z "${k:-}" ]; then
  echo "FAIL: could not extract tenantId+k from welcome URL" >&2
  exit 1
fi
echo "OK: tenantId extracted"
echo "OK: k extracted (hidden)"
echo

echo "==> 5) Send demo leads to webhook (tenantId query + x-tenant-key header)"
if [ ! -f "$LEADS" ]; then
  echo "FAIL: demo leads file missing: $LEADS" >&2
  exit 1
fi

i=0
while IFS= read -r line; do
  [ -z "${line:-}" ] && continue
  code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/api/webhook/intake?tenantId=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)" \
    -H "content-type: application/json" \
    -H "x-tenant-key: $k" \
    --data "$line" || true)"
  echo "lead[$i] => HTTP $code"
  i=$((i+1))
done < "$LEADS"
echo "OK: leads sent = $i"
echo

tickets="$BASE_URL/ui/tickets?tenantId=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)&k=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"
csv="$BASE_URL/ui/export.csv?tenantId=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)&k=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"
zip="$BASE_URL/ui/evidence.zip?tenantId=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)&k=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"
pilot="$BASE_URL/ui/pilot?tenantId=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)&k=$(python - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"

echo "==> 6) Opening Tickets + CSV + ZIP + Pilot page"
echo "Tickets: $tickets"
echo "CSV:     $csv"
echo "ZIP:     $zip"
echo "Pilot:   $pilot"

if command -v open >/dev/null 2>&1; then
  open "$pilot" || true
  open "$tickets" || true
  open "$csv" || true
  open "$zip" || true
fi

echo
echo "✅ DONE — This is the full client pilot experience."
EOF

chmod +x scripts/client_experience_a2z.sh

# -----------------------------
# 4) Ensure demo_leads.jsonl exists (simple, valid json lines)
# -----------------------------
cat > scripts/demo_leads.jsonl <<'EOF'
{"source":"demo","type":"lead","lead":{"fullName":"Alice One","email":"alice@acme.dev","company":"ACME","message":"Need help with IT support"}}
{"source":"demo","type":"lead","lead":{"fullName":"Bob Two","email":"bob@beta.dev","company":"BETA","message":"Request onboarding for new hire"}}
{"source":"demo","type":"lead","lead":{"fullName":"Carla Three","email":"carla@carla.dev","company":"CARLA","message":"Laptop setup + access policy"}}
{"source":"demo","type":"lead","lead":{"fullName":"Dan Four","email":"dan@delta.dev","company":"DELTA","message":"Security review + evidence pack"}}
{"source":"demo","type":"lead","lead":{"fullName":"Eve Five","email":"eve@echo.dev","company":"ECHO","message":"Need audit trail + export CSV"}}
EOF

# -----------------------------
# 5) typecheck
# -----------------------------
echo "==> typecheck"
pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ B2 applied"
echo "Next:"
echo "  1) Run server (if port busy): ./scripts/dev-kill-7090-and-start.sh"
echo "  2) Run client experience:     bash scripts/client_experience_a2z.sh"
echo
echo "New page (after you have tenantId+k): /ui/pilot"
echo "Backups: $BAK"
