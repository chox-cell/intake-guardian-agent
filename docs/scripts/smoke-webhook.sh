#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-}"
TENANT_KEY="${TENANT_KEY:-}"

fail(){ echo "❌ $*" >&2; exit 1; }

echo "==> [0] health"
curl -sS "$BASE_URL/health" | grep -q '"ok":true' || fail "health not ok"
echo "✅ health ok"

[ -n "$TENANT_ID" ] || fail "missing TENANT_ID"
[ -n "$TENANT_KEY" ] || fail "missing TENANT_KEY"

echo "==> [1] send webhook intake"
code="$(curl -sS -o /tmp/webhook_out.json -w "%{http_code}" \
  -X POST "$BASE_URL/api/webhook/intake" \
  -H "Content-Type: application/json" \
  -H "x-tenant-id: $TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  -d "{\"title\":\"New Lead: ACME Energy\",\"body\":\"Need risk scan + weekly brief.\",\"dedupeKey\":\"acme-energy-lead\"}")"

echo "status=$code"
cat /tmp/webhook_out.json
[ "$code" = "201" ] || fail "webhook not 201"

echo "✅ webhook ok"
