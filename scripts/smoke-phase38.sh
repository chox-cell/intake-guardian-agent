#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:?missing ADMIN_KEY}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "BASE_URL=$BASE_URL"

echo "==> health"
curl -fsS "$BASE_URL/health" >/dev/null || fail "health failed"

echo "==> Location from /ui/admin"
HDRS="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r')"
LOC="$(printf "%s\n" "$HDRS" | sed -n 's/^[Ll]ocation: //p' | head -n1)"
[ -n "$LOC" ] || fail "no Location header"

Q="${LOC#*\?}"
TENANT_ID="$(printf "%s\n" "$Q" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(printf "%s\n" "$Q" | sed -n 's/.*k=\([^&]*\).*/\1/p')"
[ -n "$TENANT_ID" ] || fail "tenantId parse failed"
[ -n "$TENANT_KEY" ] || fail "k parse failed"

DECISIONS="$BASE_URL/ui/decisions?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> ui/decisions 200"
curl -s -o /dev/null -w "%{http_code}" "$DECISIONS" | grep -q 200 || fail "ui/decisions not 200"

echo "✅ Phase38 smoke OK"
echo "UI:"
echo "  $DECISIONS"
