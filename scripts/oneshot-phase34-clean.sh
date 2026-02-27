#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase34 CLEAN OneShot @ $(pwd)"

# -------------------------
# Backup
# -------------------------
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase34_${TS}"
mkdir -p "$BAK"
cp -R scripts docs 2>/dev/null || true
cp -R scripts "$BAK/" 2>/dev/null || true
cp -R docs "$BAK/" 2>/dev/null || true
echo "OK backup -> $BAK"

mkdir -p docs/zapier/templates
mkdir -p dist/zapier-template-pack

# -------------------------
# CLIENT ONBOARDING DOC
# -------------------------
cat > docs/CLIENT_ONBOARDING.md <<'MD'
# Intake Guardian — Client Onboarding (5 minutes)

This system turns leads into:
- Deduplicated tickets
- CSV export
- Evidence ZIP (proof)

## What client receives
ONE link only:
- Tickets
- Export CSV
- Evidence ZIP

No login. No dashboard complexity.

## Step 1 — Generate client link
Run server:
ADMIN_KEY=YOUR_ADMIN_KEY pnpm dev

Open:
http://127.0.0.1:7090/ui/admin?adminKey=YOUR_ADMIN_KEY

You will be redirected to:
 /ui/tickets?tenantId=XXX&k=YYY

Send this FULL URL to the client.

tenantId = workspace  
k = access key (private)

## Step 2 — Zapier setup
Zapier → Webhooks by Zapier → POST

URL:
http://YOUR_SERVER/api/webhook/intake

Headers:
Content-Type: application/json

Body example:
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "Jane Doe",
    "email": "jane@example.com",
    "message": "Interested"
  }
}

Result:
- Ticket appears instantly
- Duplicate payloads are merged (no spam)

## Step 3 — Proof delivery
Client can download:
- Export CSV
- Evidence ZIP

Troubleshooting:
- /health returns ok
- tenantId and k exist in URL
- POST body is valid JSON
MD

# -------------------------
# ZAPIER TEMPLATE A
# -------------------------
cat > docs/zapier/templates/TEMPLATE_A_META_LEADS.md <<'MD'
# Zapier Template — Meta Lead Ads → Ticket

Trigger:
Meta Lead Ads → New Lead

Action:
Webhooks by Zapier → POST

URL:
http://YOUR_SERVER/api/webhook/intake

Headers:
Content-Type: application/json

Body:
{
  "source": "zapier",
  "type": "lead",
  "lead": {
    "fullName": "{{First Name}} {{Last Name}}",
    "email": "{{Email}}",
    "phone": "{{Phone Number}}",
    "campaign": "{{Campaign Name}}"
  }
}
MD

# -------------------------
# ZAPIER TEMPLATE B
# -------------------------
cat > docs/zapier/templates/TEMPLATE_B_GMAIL.md <<'MD'
# Zapier Template — Gmail → Ticket

Trigger:
Gmail → New Matching Email

Action:
Webhooks by Zapier → POST

URL:
http://YOUR_SERVER/api/webhook/intake

Headers:
Content-Type: application/json

Body:
{
  "source": "gmail",
  "type": "email",
  "lead": {
    "fullName": "{{From Name}}",
    "email": "{{From Email}}",
    "subject": "{{Subject}}",
    "message": "{{Body Plain}}"
  }
}
MD

# -------------------------
# PACK SCRIPT
# -------------------------
cat > scripts/zapier-template-pack.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
OUT="dist/zapier-template-pack"
mkdir -p "$OUT"
cp -R docs/zapier "$OUT/"
cp docs/CLIENT_ONBOARDING.md "$OUT/"
echo "OK Zapier pack created:"
find "$OUT" -type f
BASH
chmod +x scripts/zapier-template-pack.sh

# -------------------------
# SMOKE PHASE34
# -------------------------
cat > scripts/smoke-phase34.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "==> health"
curl -s "$BASE_URL/health" | grep -q ok || fail "health not ok"

echo "==> admin redirect"
HDR="$(curl -s -D- -o /dev/null "$BASE_URL/ui/admin?adminKey=$ADMIN_KEY")"
LOC="$(echo "$HDR" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
[ -n "$LOC" ] || fail "no Location header"

TENANT_ID="$(echo "$LOC" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$LOC" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

[ -n "$TENANT_ID" ] || fail "tenantId parse failed"
[ -n "$TENANT_KEY" ] || fail "k parse failed"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
CSV="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
ZIP="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"

curl -s -o /dev/null -w "%{http_code}" "$TICKETS" | grep -q 200 || fail "tickets not 200"
curl -s -o /dev/null -w "%{http_code}" "$CSV" | grep -q 200 || fail "csv not 200"
curl -s -o /dev/null -w "%{http_code}" "$ZIP" | grep -q 200 || fail "zip not 200"

./scripts/zapier-template-pack.sh >/dev/null

echo "OK Phase34 smoke"
echo "Client URL:"
echo "$TICKETS"
BASH
chmod +x scripts/smoke-phase34.sh

echo "DONE Phase34 CLEAN installed"
echo "Next:"
echo "ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "ADMIN_KEY=super_secret_admin_123 ./scripts/smoke-phase34.sh"
