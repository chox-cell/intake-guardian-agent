#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"

if [[ ! -f .env.local ]]; then
  echo "❌ .env.local not found in $(pwd)"
  exit 1
fi

ADMIN_KEY="$(grep -E '^ADMIN_KEY=' .env.local | tail -n1 | cut -d= -f2- | tr -d '\r')"
if [[ -z "${ADMIN_KEY:-}" ]]; then
  echo "❌ ADMIN_KEY missing in .env.local"
  exit 1
fi

echo "==> Rotating tenant key"
resp="$(curl -sS -X POST "$BASE_URL/api/admin/tenants/rotate" \
  -H "x-admin-key: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"tenantId\":\"$TENANT_ID\"}")"

echo "$resp" | python3 - <<'PY'
import json,sys
o=json.load(sys.stdin)
if not o.get("ok"):
  print("❌ rotate failed:", o)
  sys.exit(1)
print("✅ tenantId:", o.get("tenantId"))
print("✅ tenantKey:", o.get("tenantKey"))
PY
