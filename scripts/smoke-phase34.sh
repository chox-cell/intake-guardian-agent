#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "BASE_URL=$BASE_URL"

echo "==> health"
curl -fsS "$BASE_URL/health" >/dev/null || fail "health failed"

echo "==> /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui" || true)"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden (expected 404)"

echo "==> /ui/admin redirect (302 expected) + capture Location"
[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY. Use: ADMIN_KEY=... BASE_URL=... ./scripts/smoke-phase34.sh"

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

[ -n "${TENANT_ID:-}" ] || fail "tenantId parse failed"
[ -n "${TENANT_KEY:-}" ] || fail "k parse failed"

echo "==> tickets 200"
TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
curl -sS -o /dev/null -w "%{http_code}" "$TICKETS" | grep -q 200 || fail "tickets not 200: $TICKETS"

echo "==> export.csv 200"
CSV="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
curl -sS -o /dev/null -w "%{http_code}" "$CSV" | grep -q 200 || fail "csv not 200: $CSV"

echo "==> evidence.zip 200 (or 404 if not shipped)"
ZIP="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$ZIP" || true)"
echo "status=$code"
if [ "$code" != "200" ] && [ "$code" != "404" ]; then
  fail "zip unexpected status $code: $ZIP"
fi

echo "==> zapier pack output"
if [ -x "./scripts/zapier-pack.sh" ]; then
  ./scripts/zapier-pack.sh >/dev/null 2>&1 || true
fi

echo
echo "✅ Phase34 smoke OK"
echo "Client URL:"
echo "  $TICKETS"
echo "Setup URL:"
echo "  $BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
echo "Export CSV:"
echo "  $CSV"
echo "Evidence ZIP:"
echo "  $ZIP"
