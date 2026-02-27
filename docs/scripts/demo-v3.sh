#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq missing (brew install jq)"; exit 1; }

BASE_URL="${BASE_URL:-http://localhost:7090}"
ADMIN_KEY="${ADMIN_KEY:-dev_admin_key_123}"

TS="$(date +%s)"
TENANT_ID="tenant_demo_$TS"

echo "==> 1) Create tenant"
CREATED="$(curl -sS "$BASE_URL/api/admin/tenants/create" \
  -H "x-admin-key: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"tenantId\":\"$TENANT_ID\"}")"
echo "$CREATED" | jq .

TENANT_KEY="$(echo "$CREATED" | jq -r '.tenantKey')"

echo
echo "==> 2) Create ticket (SendGrid-style inbound)"
SUBJECT="Demo IT Request $TS"
BODY="VPN is down ASAP. Cannot access network. demo_ts=$TS"

RESP="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F "from=employee@corp.local" \
  -F "subject=$SUBJECT" \
  -F "text=$BODY")"
echo "$RESP" | jq .

WID="$(echo "$RESP" | jq -r '.workItem.id // empty')"

echo
echo "==> 3) Stats proof"
curl -sS "$BASE_URL/api/admin/stats?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" | jq .

echo
echo "==> 4) Export CSV (first lines)"
curl -sS "$BASE_URL/api/admin/export.csv?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" | head -n 5

echo
echo "==> 5) Optional: Slack outbound (if SLACK_WEBHOOK_URL set)"
curl -sS "$BASE_URL/api/outbound/slack?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"workItemId\":\"$WID\"}" | jq . || true

echo
echo "✅ Demo v3 done."
