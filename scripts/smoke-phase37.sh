#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:?missing ADMIN_KEY}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "BASE_URL=$BASE_URL"

echo "==> health"
curl -fsS "$BASE_URL/health" >/dev/null || fail "health failed"

echo "==> get Location from /ui/admin (robust, macOS-safe)"
HDRS="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r')"
echo "---- debug headers ----"
echo "$HDRS"

# Extract Location header safely (no awk IGNORECASE)
LOC="$(printf "%s\n" "$HDRS" | sed -n 's/^[Ll]ocation: //p' | head -n1)"
[ -n "$LOC" ] || fail "no Location header"

echo "Location=$LOC"

# Parse query params
Q="${LOC#*\?}"

TENANT_ID="$(printf "%s\n" "$Q" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(printf "%s\n" "$Q" | sed -n 's/.*k=\([^&]*\).*/\1/p')"

[ -n "$TENANT_ID" ] || fail "tenantId parse failed"
[ -n "$TENANT_KEY" ] || fail "k parse failed"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
CSV="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
ZIP="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
DECISIONS="$BASE_URL/ui/decisions?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> tickets 200"
curl -s -o /dev/null -w "%{http_code}" "$TICKETS" | grep -q 200 || fail "tickets not 200"

echo "==> export.csv 200"
curl -s -o /dev/null -w "%{http_code}" "$CSV" | grep -q 200 || fail "csv not 200"

echo "==> evidence.zip 200 or 404"
CODE_ZIP="$(curl -s -o /dev/null -w "%{http_code}" "$ZIP" || true)"
echo "status=$CODE_ZIP"
[ "$CODE_ZIP" = "200" ] || [ "$CODE_ZIP" = "404" ] || fail "zip unexpected status $CODE_ZIP"

echo "==> ui/decisions 200"
curl -s -o /dev/null -w "%{http_code}" "$DECISIONS" | grep -q 200 || fail "ui/decisions not 200"

echo
echo "✅ Phase37 smoke OK"
echo "Tickets:"
echo "  $TICKETS"
echo "Decisions:"
echo "  $DECISIONS"
echo "CSV:"
echo "  $CSV"
echo "ZIP:"
echo "  $ZIP"
