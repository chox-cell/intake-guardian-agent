#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:?missing ADMIN_KEY}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "BASE_URL=$BASE_URL"
echo "==> health"
curl -sS "$BASE_URL/health" >/dev/null || fail "health failed"

echo "==> Location from /ui/admin"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r')"
loc="$(printf "%s\n" "$hdr" | awk -F': ' 'BEGIN{IGNORECASE=1} tolower($1)=="location"{print $2; exit}')"
[ -n "$loc" ] || { echo "---- debug headers ----"; echo "$hdr"; fail "no Location header"; }
echo "Location=$loc"

TENANT_ID="$(printf "%s" "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(printf "%s" "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "$TENANT_ID" ] || fail "tenantId parse failed"
[ -n "$TENANT_KEY" ] || fail "k parse failed"

TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
SETUP="$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
DECISIONS="$BASE_URL/ui/decisions?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> tickets 200 + themed"
curl -s -o /dev/null -w "%{http_code}" "$TICKETS" | grep -q 200 || fail "tickets not 200"
curl -s "$TICKETS" | grep -q 'data-dc-theme="1"' || fail "tickets not themed"

echo "==> setup 200 + themed"
curl -s -o /dev/null -w "%{http_code}" "$SETUP" | grep -q 200 || fail "setup not 200"
curl -s "$SETUP" | grep -q 'data-dc-theme="1"' || fail "setup not themed"

echo "==> decisions 200 + themed"
curl -s -o /dev/null -w "%{http_code}" "$DECISIONS" | grep -q 200 || fail "decisions not 200"
curl -s "$DECISIONS" | grep -q 'data-dc-theme="1"' || fail "decisions not themed"

echo
echo "✅ Phase41 smoke OK"
echo "Tickets:"
echo "  $TICKETS"
echo "Setup:"
echo "  $SETUP"
echo "Decisions:"
echo "  $DECISIONS"
