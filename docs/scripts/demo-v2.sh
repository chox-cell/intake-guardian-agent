#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq missing (brew install jq)"; exit 1; }

BASE_URL="${BASE_URL:-http://localhost:7090}"
TENANT="${TENANT:-tenant_demo}"
KEY="${TENANT_KEY:-dev_key_123}"

TS="$(date +%s)"
SUBJECT="Demo IT Request $TS"
BODY="VPN is down ASAP. Cannot access network. demo_ts=$TS"

echo "==> 1) Create ticket"
RESP="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -H "x-tenant-key: $KEY" \
  -F "from=employee@corp.local" \
  -F "subject=$SUBJECT" \
  -F "text=$BODY")"
echo "$RESP" | jq .

WID="$(echo "$RESP" | jq -r '.workItem.id // empty')"
if [ -z "$WID" ]; then
  echo "ERROR: could not capture workItemId"
  exit 1
fi

echo
echo "==> 2) Stats proof"
curl -sS "$BASE_URL/api/admin/stats?tenantId=$TENANT" \
  -H "x-tenant-key: $KEY" | jq .

echo
echo "==> 3) Optional: Slack outbound"
curl -sS "$BASE_URL/api/outbound/slack?tenantId=$TENANT" \
  -H "x-tenant-key: $KEY" \
  -H "Content-Type: application/json" \
  -d "{\"workItemId\":\"$WID\"}" | jq . || true

echo
echo "✅ Demo done."
