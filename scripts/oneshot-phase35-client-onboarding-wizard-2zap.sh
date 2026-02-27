#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Phase35 OneShot (Client Onboarding Wizard + 2 Zapier Templates) @ $ROOT"

[ -d "src" ] || { echo "❌ src missing (run inside repo root)"; exit 1; }
[ -d "scripts" ] || { echo "❌ scripts missing (run inside repo root)"; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase35_${STAMP}"
mkdir -p "$BAK"
cp -R src scripts docs package.json tsconfig.json "$BAK" 2>/dev/null || true
echo "✅ backup -> $BAK"

mkdir -p docs/zapier/templates docs/onboarding

# -------------------------
# [1] Onboarding docs
# -------------------------
cat > docs/onboarding/CLIENT_ONBOARDING.md <<'MD'
# Agency Webhook Intake Tool — Client Onboarding (3 minutes)

## What this tool does
Any lead coming from Meta/Typeform/Calendly (via Zapier) becomes:
- a **deduped ticket** (no duplicates)
- exportable **CSV**
- downloadable **Evidence ZIP**

## Step 0 — You only need 2 things
- `tenantId`
- `k` (tenant key)

You will get them automatically from the Admin Start Link (below).

---

## Step 1 — Admin creates a client link (one click)
Open this in the browser:

`/ui/start?adminKey=YOUR_ADMIN_KEY`

It will redirect you to `/ui/setup?...` with **tenantId + k already filled**.

---

## Step 2 — Client uses 3 URLs (copy/paste)
From `/ui/setup` you will see:

- Tickets page (client view)
- Export CSV
- Evidence ZIP

---

## Step 3 — Zapier setup (choose one template)
We provide 2 templates:

1) **Lead Intake Template** (Meta/Typeform/Website form → Ticket)
2) **Booking Intake Template** (Calendly → Ticket)

Each template posts JSON to:
`POST /api/webhook/intake`

---

## Support
If the client loses access, admin regenerates a new key:
Use the Admin Start Link again, or rotate keys (advanced).
MD

# -------------------------
# [2] Two Zapier templates (docs)
# -------------------------
cat > docs/zapier/templates/01_lead_intake.md <<'MD'
# Zapier Template 01 — Lead Intake (Meta/Typeform/Web Form → Ticket)

## Trigger examples
- Facebook Lead Ads
- Typeform “New Entry”
- Tally / Google Forms submission
- Webflow form

## Action
**Webhooks by Zapier → POST**

URL:
`http://YOUR_BASE_URL/api/webhook/intake?tenantId=YOUR_TENANT_ID&k=YOUR_TENANT_KEY`

Headers:
`Content-Type: application/json`

Body (example):
```json
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
}✅ Result: ticket created or deduped (same person → no duplicates).
MD

cat > docs/zapier/templates/02_booking_intake.md <<‘MD’

Zapier Template 02 — Booking Intake (Calendly → Ticket)

Trigger
	•	Calendly “Invitee Created”
(or Google Calendar “New Event”)

Action

Webhooks by Zapier → POST

URL:
http://YOUR_BASE_URL/api/webhook/intake?tenantId=YOUR_TENANT_ID&k=YOUR_TENANT_KEY

Headers:
Content-Type: application/json

Body (example):{
  "source": "zapier",
  "type": "booking",
  "booking": {
    "fullName": "John Smith",
    "email": "john@example.com",
    "event": "Discovery Call",
    "whenUtc": "2026-01-05T16:00:00Z",
    "notes": "Needs e-commerce growth plan"
  }
}✅ Result: ticket created or deduped.
MD

———————––

[3] Add /ui/start route (wizard redirect)

- Admin enters adminKey once → we redirect to /ui/setup with tenantId+k.

———————––

mkdir -p src/ui
cat > src/ui/start_route.ts <<‘TS’
import type { Express, Request, Response } from “express”;
import { createTenant, getOrCreateDemoTenant } from “../lib/tenant_registry.js”;

function safeBaseUrl(req: Request) {
const proto = (req.headers[“x-forwarded-proto”] as string) || “http”;
const host = (req.headers[“x-forwarded-host”] as string) || req.headers.host || “127.0.0.1”;
return ${proto}://${host};
}

function isAdminOk(req: Request) {
const want = process.env.ADMIN_KEY || “”;
const got =
(req.query.adminKey as string) ||
(req.query.admin as string) ||
(req.query.key as string) ||
“”;
return Boolean(want) && got === want;
}

export function mountStart(app: Express) {
app.get(”/ui/start”, async (req: Request, res: Response) => {
if (!isAdminOk(req)) return res.status(401).send(“unauthorized”);const fresh = String(req.query.fresh || "") === "1";
const tenant = fresh ? await createTenant("Client (fresh)") : await getOrCreateDemoTenant();

const baseUrl = safeBaseUrl(req);
const setup = `${baseUrl}/ui/setup?tenantId=${encodeURIComponent(tenant.tenantId)}&k=${encodeURIComponent(tenant.tenantKey)}`;
return res.redirect(302, setup);});
}
TS

———————––

[4] Patch server.ts to mountStart (robust, non-breaking)

———————––

SERVER=“src/server.ts”
[ -f “$SERVER” ] || { echo “❌ missing $SERVER”; exit 1; }
cp “$SERVER” “${SERVER}.bak.${STAMP}”

node - <<‘NODE’
const fs = require(“fs”);
const path = “src/server.ts”;
let s = fs.readFileSync(path, “utf8”);

const importLine = import { mountStart } from "./ui/start_route.js";;
if (!s.includes(importLine)) {
// Put near other ui imports if found, else top section.
const lines = s.split(”\n”);
let inserted = false;
for (let i=0;i<lines.length;i++){
if (lines[i].includes(‘from “./ui/’) || lines[i].includes(“from ’./ui/”)) {
// insert after last ui import block later; we’ll just insert after first ui import.
lines.splice(i+1, 0, importLine);
inserted = true;
break;
}
}
if (!inserted) {
// insert after first import line
const idx = lines.findIndex(l => l.startsWith(“import “));
lines.splice(Math.max(0, idx+1), 0, importLine);
}
s = lines.join(”\n”);
}

if (!s.includes(“mountStart(app)”)) {
// mount right after mountSetup(app) if exists; else near other mount calls.
const needle = “mountSetup(app”;
if (s.includes(needle)) {
s = s.replace(/mountSetup(app[^)]);\s\n/, m => m + “  mountStart(app);\n”);
} else {
// try after app is created
const appNeedle = “const app = express()”;
if (s.includes(appNeedle)) {
s = s.replace(appNeedle, appNeedle + “;\n\n  // Phase35: Admin Start Wizard\n  mountStart(app)”);
// ensure semicolons
s = s.replace(“mountStart(app)\n”, “mountStart(app);\n”);
} else {
// append near end as last resort (still safe)
s += “\n\n// Phase35: Admin Start Wizard\nmountStart(app);\n”;
}
}
}

fs.writeFileSync(path, s);
console.log(“✅ patched src/server.ts (mountStart)”);
NODE

———————––

[5] Zapier pack script output folder

———————––

cat > scripts/zapier-template-pack.sh <<‘BASH’
#!/usr/bin/env bash
set -euo pipefail
ROOT=”$(cd “$(dirname “${BASH_SOURCE[0]}”)/..” && pwd)”
cd “$ROOT”

OUT=“dist/zapier-template-pack”
rm -rf “$OUT”
mkdir -p “$OUT/templates” “$OUT/onboarding”

cp -f docs/onboarding/CLIENT_ONBOARDING.md “$OUT/onboarding/CLIENT_ONBOARDING.md”
cp -f docs/zapier/templates/01_lead_intake.md “$OUT/templates/01_lead_intake.md”
cp -f docs/zapier/templates/02_booking_intake.md “$OUT/templates/02_booking_intake.md”

cat > “$OUT/README.txt” <<‘TXT’
Zapier Template Pack
	•	onboarding/CLIENT_ONBOARDING.md
	•	templates/01_lead_intake.md
	•	templates/02_booking_intake.md
TXT

echo “✅ wrote $OUT”
BASH
chmod +x scripts/zapier-template-pack.sh

———————––

[6] Smoke phase35 (macOS-friendly Location parsing)

———————––

cat > scripts/smoke-phase35.sh <<‘BASH’
#!/usr/bin/env bash
set -euo pipefail
BASE_URL=”${BASE_URL:-http://127.0.0.1:7090}”
ADMIN_KEY=”${ADMIN_KEY:-}”

fail(){ echo “FAIL: $*”; exit 1; }

echo “BASE_URL=$BASE_URL”
[ -n “$ADMIN_KEY” ] || fail “missing ADMIN_KEY”

echo “==> health”
curl -sS “$BASE_URL/health” >/dev/null || fail “health failed”

echo “==> /ui hidden (404 expected)”
s1=”$(curl -sS -o /dev/null -w ‘%{http_code}’ “$BASE_URL/ui” || true)”
echo “status=$s1”
[ “$s1” = “404” ] || fail “/ui not hidden”

echo “==> /ui/admin redirect (302) capture Location”
hdr=”$(curl -sS -D- -o /dev/null “$BASE_URL/ui/admin?admin=$ADMIN_KEY” | tr -d ‘\r’)”
loc=”$(printf “%s\n” “$hdr” | awk -F’: ’ ‘BEGIN{IGNORECASE=1} $1==“location”{print $2; exit}’)”
[ -n “$loc” ] || { echo “–– debug headers ––”; echo “$hdr”; fail “no Location header from /ui/admin”; }
echo “Location=$loc”

q=”${loc#?}”
TENANT_ID=”$(echo “$q” | sed -n ’s/^tenantId=([^&])./\1/p; s/.[?&]tenantId=([^&])./\1/p’)”
TENANT_KEY=”$(echo “$q” | sed -n ‘s/^k=([^&])./\1/p; s/.[?&]k=([^&]).*/\1/p’)”

echo “TENANT_ID=$TENANT_ID”
echo “TENANT_KEY=$TENANT_KEY”
[ -n “$TENANT_ID” ] || fail “tenantId parse failed”
[ -n “$TENANT_KEY” ] || fail “k parse failed”

TICKETS=”$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY”
CSV=”$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY”
ZIP=”$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY”
SETUP=”$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY”
START=”$BASE_URL/ui/start?adminKey=$ADMIN_KEY”

echo “==> tickets 200”
curl -s -o /dev/null -w “%{http_code}” “$TICKETS” | grep -q 200 || fail “tickets not 200”

echo “==> export.csv 200”
curl -s -o /dev/null -w “%{http_code}” “$CSV” | grep -q 200 || fail “csv not 200”

echo “==> evidence.zip 200 (or 404 if disabled)”
codeZip=”$(curl -s -o /dev/null -w “%{http_code}” “$ZIP” || true)”
echo “status=$codeZip”
[ “$codeZip” = “200” ] || [ “$codeZip” = “404” ] || fail “zip unexpected status=$codeZip”

echo “==> /ui/setup 200”
curl -s -o /dev/null -w “%{http_code}” “$SETUP” | grep -q 200 || fail “setup not 200”

echo “==> /ui/start 302”
codeStart=”$(curl -s -o /dev/null -w “%{http_code}” “$START” || true)”
echo “status=$codeStart”
[ “$codeStart” = “302” ] || fail “start not 302”

echo “==> zapier template pack output”
./scripts/zapier-template-pack.sh >/dev/null
[ -f dist/zapier-template-pack/onboarding/CLIENT_ONBOARDING.md ] || fail “missing onboarding in pack”
[ -f dist/zapier-template-pack/templates/01_lead_intake.md ] || fail “missing template 01”
[ -f dist/zapier-template-pack/templates/02_booking_intake.md ] || fail “missing template 02”
echo “✅ pack ok”

echo
echo “✅ Phase35 smoke OK”
echo “Client URL:”
echo “  $TICKETS”
echo “Setup URL:”
echo “  $SETUP”
echo “Start Wizard:”
echo “  $START”
echo “Docs pack:”
echo “  dist/zapier-template-pack/”
BASH
chmod +x scripts/smoke-phase35.sh

echo
echo “✅ Phase35 installed.”
echo “Now run in TWO terminals:”
echo “  (A) ADMIN_KEY=super_secret_admin_123 pnpm dev”
echo “  (B) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase35.sh”
echo
echo “Open wizard:”
echo “  http://127.0.0.1:7090/ui/start?adminKey=super_secret_admin_123”
