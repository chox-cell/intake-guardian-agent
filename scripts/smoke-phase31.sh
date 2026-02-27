#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "BASE_URL=$BASE_URL"

echo "==> [0] health"
curl -fsS "$BASE_URL/health" >/dev/null || fail "health failed"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui" || true)"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden (expected 404)"

echo "==> [2] /ui/admin redirect (302 expected) + capture Location"
[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY. Use: ADMIN_KEY=... BASE_URL=... ./scripts/smoke-phase31.sh"

adminUrl="$BASE_URL/ui/admin?admin=$ADMIN_KEY"
headers="$(curl -sS -D- -o /dev/null "$adminUrl" | tr -d '\r')"
loc="$(printf "%s" "$headers" | grep -i '^location:' | head -n 1 | sed -E 's/^[Ll]ocation:[[:space:]]*//')"

if [ -z "${loc:-}" ]; then
  echo "---- debug headers ----"
  echo "$headers"
  fail "no Location header from /ui/admin"
fi

echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

[ -n "${TENANT_ID:-}" ] || fail "tenantId parse failed from Location: $loc"
[ -n "${TENANT_KEY:-}" ] || fail "k parse failed from Location: $loc"

echo "==> [3] tickets should be 200"
TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "$TICKETS" || true)"
echo "status=$s3"
[ "$s3" = "200" ] || fail "tickets not 200: $TICKETS"

echo "==> [4] export.csv should be 200"
CSV="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
s4="$(curl -sS -o /dev/null -w "%{http_code}" "$CSV" || true)"
echo "status=$s4"
[ "$s4" = "200" ] || fail "csv not 200: $CSV"

echo "==> [5] /ui/setup should be 200"
SETUP="$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
s5="$(curl -sS -o /dev/null -w "%{http_code}" "$SETUP" || true)"
echo "status=$s5"
[ "$s5" = "200" ] || fail "setup not 200: $SETUP"

echo
echo "✅ Phase31 smoke OK"
echo "Client URL:"
echo "  $TICKETS"
echo "Setup URL:"
echo "  $SETUP"
echo "Export CSV:"
echo "  $CSV"
