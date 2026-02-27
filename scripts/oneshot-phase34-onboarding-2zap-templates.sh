#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase34 OneShot (Onboarding + 2 Zapier templates + smoke-phase34) @ $(pwd)"

# --- backup (light) ---
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase34_${ts}"
mkdir -p "$bak"
cp -R scripts docs 2>/dev/null || true
cp -R scripts "$bak/" 2>/dev/null || true
cp -R docs "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak"

mkdir -p docs/zapier/templates
mkdir -p dist/zapier-template-pack

# -------------------------
# Docs: Client onboarding (super clear)
# -------------------------
cat > docs/CLIENT_ONBOARDING.md <<'MD'
# Agency Webhook Intake Tool — Client Onboarding (5 minutes)

This tool turns incoming leads into **deduped tickets** + **CSV export** + **Evidence ZIP**.

## What the client gets (zero logins)
You will give the client **one link**:
- Tickets page (live list)
- Export CSV
- Evidence ZIP (proof pack)

## Step 1 — Get the client link (tenantId + k)
You (agency/admin) generate the client link using the admin autolink:

1) Run the server:
- `ADMIN_KEY=YOUR_ADMIN_KEY pnpm dev`

2) Open:
- `http://127.0.0.1:7090/ui/admin?adminKey=YOUR_ADMIN_KEY`

This redirects you to:
- `/ui/tickets?tenantId=...&k=...`

✅ Copy that full URL and give it to the client.  
**tenantId** = client workspace  
**k** = client access key (keep it private)

## Step 2 — Connect Zapier (no code)
In Zapier, create a Zap:

### Trigger (choose one)
- Meta Lead Ads / Typeform / Calendly / Gmail / etc.

### Action
- **Webhooks by Zapier → POST**

**URL**
- `http://YOUR_SERVER/api/webhook/intake`

**Headers**
- `Content-Type: application/json`

**Body (example)**
```json
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "Jane Doe",
    "email": "jane@example.com",
    "company": "Acme",
    "message": "Need help with ads",
    "utm": {"source":"meta","campaign":"winter"}
  }
}✅ Result: ticket appears instantly in client Tickets page.
✅ Dedupe: if Zapier sends the same payload again, it updates duplicateCount (no new ticket).

Step 3 — Deliver proof

Client can download:
•Export CSV
•Evidence ZIP (shareable proof pack)

Support checklist (when client says “it doesn’t work”)
•Server health: /health
•Client link has tenantId and k
•Zapier action is POST and JSON is valid
•They didn’t paste <...> placeholders
MD

———————––

Zapier Templates (2)

———————––

cat > docs/zapier/templates/TEMPLATE_A_META_LEADS.md <<‘MD’

Zapier Template A — Meta Lead Ads → Intake-Guardian Ticket

Use case

Automatically capture new Meta/Facebook lead into a deduped ticket.

Zap steps
1.Trigger:

•Meta Lead Ads → New Lead

2.Action:

•Webhooks by Zapier → POST

Webhook settings

URL:
•http://YOUR_SERVER/api/webhook/intake

Headers:
•Content-Type: application/json

Data (JSON):{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "{{First Name}} {{Last Name}}",
    "email": "{{Email}}",
    "phone": "{{Phone Number}}",
    "formId": "{{Form ID}}",
    "adId": "{{Ad ID}}",
    "campaign": "{{Campaign Name}}",
    "message": "{{Any Custom Answers}}"
  }
}Expected result
•Ticket title: “Lead intake (zapier)”
•Status becomes “ready”
•Duplicate sends do NOT create new tickets (duplicateCount increments)
MD

cat > docs/zapier/templates/TEMPLATE_B_GMAIL_TO_TICKET.md <<‘MD’

Zapier Template B — Gmail → Intake-Guardian Ticket

Use case

Turn inbound emails into tickets (good for agencies using Gmail as lead inbox).

Zap steps
1.Trigger:

•Gmail → New Email Matching Search
Search example:
•label:leads OR subject:(quote OR proposal OR help)

2.Action:

•Webhooks by Zapier → POST

Webhook settings

URL:
•http://YOUR_SERVER/api/webhook/intake

Headers:
•Content-Type: application/json

Data (JSON):{
  "source": "gmail",
  "type": "email",
  "lead": {
    "fullName": "{{From Name}}",
    "email": "{{From Email}}",
    "subject": "{{Subject}}",
    "message": "{{Body Plain}}"
  }
}Expected result
•Ticket created as “ready”
•Evidence ZIP becomes your “handoff proof pack” to client
MD———————––

Script: pack templates to dist (Gumroad-friendly asset)

———————––

cat > scripts/zapier-template-pack.sh <<‘BASH’
#!/usr/bin/env bash
set -euo pipefail
out=“dist/zapier-template-pack”
mkdir -p “$out”
cp -R docs/zapier “$out/”
cp docs/CLIENT_ONBOARDING.md “$out/” || true
echo “✅ Zapier template pack -> $out”
echo “Files:”
find “$out” -maxdepth 3 -type f | sed ‘s/^/  - /’
BASH
chmod +x scripts/zapier-template-pack.sh

———————––

Script: onboard helper (prints EXACT client URLs + test curl)

———————––

cat > scripts/onboard-client.sh <<‘BASH’
#!/usr/bin/env bash
set -euo pipefail

BASE_URL=”${BASE_URL:-http://127.0.0.1:7090}”
ADMIN_KEY=”${ADMIN_KEY:-}”

if [ -z “$ADMIN_KEY” ]; then
echo “❌ Missing ADMIN_KEY. Run like:”
echo “  ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/onboard-client.sh”
exit 1
fi

echo “==> [0] health”
curl -sS “$BASE_URL/health” >/dev/null && echo “✅ health ok”

echo “==> [1] get Location from /ui/admin redirect”
hdr=”$(curl -sS -D- -o /dev/null “$BASE_URL/ui/admin?adminKey=$ADMIN_KEY”)”
loc=”$(printf “%s” “$hdr” | awk -F’: ’ ‘tolower($1)==“location”{print $2}’ | tr -d ‘\r’ | tail -n 1)”

if [ -z “${loc:-}” ]; then
echo “–– debug headers ––”
echo “$hdr” | head -n 30
echo “❌ No Location header (redirect). Check server + ADMIN_KEY.”
exit 1
fi

echo “Location=$loc”

TENANT_ID=”$(echo “$loc” | sed -n ‘s/.[?&]tenantId=([^&])./\1/p’)”
TENANT_KEY=”$(echo “$loc” | sed -n ’s/.[?&]k=([^&])./\1/p’)”

if [ -z “${TENANT_ID:-}” ] || [ -z “${TENANT_KEY:-}” ]; then
echo “❌ Could not parse tenantId/k from Location.”
echo “Location=$loc”
exit 1
fi

echo “TENANT_ID=$TENANT_ID”
echo “TENANT_KEY=$TENANT_KEY”
echo
echo “==> Give these to your CLIENT:”
echo “Tickets:”
echo “  $BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY”
echo “Export CSV:”
echo “  $BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY”
echo “Evidence ZIP:”
echo “  $BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY”
echo
echo “==> Zapier POST URL:”
echo “  $BASE_URL/api/webhook/intake”
echo
echo “==> Quick test (copy/paste):”
cat <<EOF
curl -sS -X POST “$BASE_URL/api/webhook/intake” \
-H “Content-Type: application/json” \
-d ‘{“source”:“zapier”,“type”:“lead”,“tenantId”:”$TENANT_ID”,“k”:”$TENANT_KEY”,“lead”:{“fullName”:“Test Lead”,“email”:“test@example.com”,“message”:“hello”}}’
EOF
BASH
chmod +x scripts/onboard-client.sh

———————––

Smoke Phase34 (UI + webhook + pack)

———————––

cat > scripts/smoke-phase34.sh <<‘BASH’
#!/usr/bin/env bash
set -euo pipefail

BASE_URL=”${BASE_URL:-http://127.0.0.1:7090}”
ADMIN_KEY=”${ADMIN_KEY:-}”

fail(){ echo “FAIL: $*”; exit 1; }

echo “==> [0] health”
curl -sS “$BASE_URL/health” >/dev/null || fail “health not ok”
echo “✅ health ok”

echo “==> [1] /ui hidden (404 expected)”
s1=”$(curl -sS -o /dev/null -w “%{http_code}” “$BASE_URL/ui”)”
echo “status=$s1”
[ “$s1” = “404” ] || fail “/ui should be hidden”

echo “==> [2] /ui/admin redirect (302) + capture Location”
[ -n “$ADMIN_KEY” ] || fail “missing ADMIN_KEY”
hdr=”$(curl -sS -D- -o /dev/null “$BASE_URL/ui/admin?adminKey=$ADMIN_KEY”)”
loc=”$(printf “%s” “$hdr” | awk -F’: ’ ‘tolower($1)==“location”{print $2}’ | tr -d ‘\r’ | tail -n 1)”
[ -n “${loc:-}” ] || { echo “$hdr” | head -n 30; fail “no Location header”; }

echo “Location=$loc”
TENANT_ID=”$(echo “$loc” | sed -n ‘s/.[?&]tenantId=([^&])./\1/p’)”
TENANT_KEY=”$(echo “$loc” | sed -n ’s/.[?&]k=([^&])./\1/p’)”
echo “TENANT_ID=$TENANT_ID”
echo “TENANT_KEY=$TENANT_KEY”
[ -n “$TENANT_ID” ] || fail “tenantId parse failed”
[ -n “$TENANT_KEY” ] || fail “k parse failed”

echo “==> [3] tickets should be 200”
tickets=”$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY”
s3=”$(curl -sS -o /dev/null -w “%{http_code}” “$tickets”)”
echo “status=$s3”
[ “$s3” = “200” ] || fail “tickets not 200”

echo “==> [4] export.csv should be 200”
csv=”$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY”
s4=”$(curl -sS -o /dev/null -w “%{http_code}” “$csv”)”
echo “status=$s4”
[ “$s4” = “200” ] || fail “csv not 200”

echo “==> [5] evidence.zip should be 200”
zip=”$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY”
s5=”$(curl -sS -o /dev/null -w “%{http_code}” “$zip”)”
echo “status=$s5”
[ “$s5” = “200” ] || fail “zip not 200”

echo “==> [6] template pack output”
./scripts/zapier-template-pack.sh >/dev/null
[ -f dist/zapier-template-pack/CLIENT_ONBOARDING.md ] || fail “missing onboarding in pack”
echo “✅ pack ok”

echo
echo “✅ Phase34 smoke OK”
echo “Client:”
echo “  $tickets”
echo “Setup:”
echo “  $BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY”
echo “Docs pack:”
echo “  dist/zapier-template-pack/”
BASH
chmod +x scripts/smoke-phase34.sh

echo
echo “✅ Phase34 installed.”
echo “Now run:”
echo “  1) ADMIN_KEY=super_secret_admin_123 pnpm dev”
echo “  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase34.sh”
echo “  3) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/onboard-client.sh”
