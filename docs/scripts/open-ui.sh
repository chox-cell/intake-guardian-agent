#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"

echo "==> Get a fresh tenant key (rotate)"
out="$(BASE_URL="$BASE_URL" TENANT_ID="$TENANT_ID" ./scripts/tenant-key.sh)"
TENANT_KEY="$(echo "$out" | sed -n 's/^✅ tenantKey: //p' | tail -n1)"

if [[ -z "${TENANT_KEY:-}" ]]; then
  echo "❌ could not parse tenantKey"
  echo "$out"
  exit 1
fi

echo
echo "==> Open UI"
echo "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
open "$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY" || true

echo
echo "==> Test export (should download CSV)"
echo "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
open "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY" || true

echo
echo "==> Curl export headers (sanity)"
curl -sSI "$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY" | sed -n '1,20p'
