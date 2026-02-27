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
