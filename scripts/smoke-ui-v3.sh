#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-dev_key_123}"

echo "==> [1] health"
curl -sS "$BASE_URL/api/health" | jq -e '.ok==true' >/dev/null
echo "✅ health ok"

echo "==> [2] ingest ticket"
SUBJECT="UIv3 Smoke $(date +%s)"
RESP="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F "subject=$SUBJECT" \
  -F 'text=wifi down ui-v3 smoke')"
echo "$RESP" | jq .
WID="$(echo "$RESP" | jq -r '.workItem.id')"
test -n "$WID"

echo "==> [3] UI tickets page (tenantKey query, dev)"
HTTP="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY")"
test "$HTTP" = "200"
echo "✅ ui tickets ok"

echo "==> [4] export csv"
HTTP2="$(curl -sS -o /tmp/tickets.csv -w "%{http_code}" "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY")"
test "$HTTP2" = "200"
head -n 2 /tmp/tickets.csv
echo "✅ export ok"

echo "==> [5] stats json"
curl -sS "$BASE_URL/ui/stats.json?tenantId=$TENANT_ID&k=$TENANT_KEY" | jq -e '.ok==true' >/dev/null
echo "✅ stats ok"

echo "==> Summary PASS"
