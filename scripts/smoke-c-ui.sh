#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-}"
TENANT_KEY="${TENANT_KEY:-}"

if [ -z "$TENANT_ID" ] || [ -z "$TENANT_KEY" ]; then
  echo "❌ Missing TENANT_ID / TENANT_KEY"
  echo "Set them like:"
  echo "  export TENANT_ID=tenant_..."
  echo "  export TENANT_KEY=..."
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jq missing (brew install jq)"; exit 1; }

echo "==> [1] health"
curl -sS "$BASE_URL/api/health" | jq . >/dev/null
echo "✅ health ok"

echo "==> [2] ingest email ticket"
SUBJECT="UI Smoke $(date +%s)"
RESP="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F "subject=$SUBJECT" \
  -F 'text=wifi down ui-smoke' )"
echo "$RESP" | jq .

ok="$(echo "$RESP" | jq -r '.ok')"
if [ "$ok" != "true" ]; then
  echo "❌ ingest failed"
  exit 1
fi

echo "==> [3] UI tickets page should be 200"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY")"
[ "$code" = "200" ] && echo "✅ ui ok" || { echo "❌ ui http=$code"; exit 1; }

echo "==> [4] Export CSV should return header"
headLine="$(curl -sS "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY" | head -n 1)"
echo "$headLine"
echo "$headLine" | grep -q "id,tenantId,source" && echo "✅ export ok" || { echo "❌ export header missing"; exit 1; }

echo "==> [5] Stats JSON should be ok:true"
curl -sS "$BASE_URL/ui/stats.json?tenantId=$TENANT_ID&k=$TENANT_KEY" | jq -e '.ok == true' >/dev/null
echo "✅ stats ok"

echo "==> Summary"
echo "PASS=5"
