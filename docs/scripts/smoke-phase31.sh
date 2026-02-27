#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
curl -s "$BASE_URL/health" >/dev/null || fail "health not ok"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden"

echo "==> [2] /ui/admin redirect (302) + capture Location"
[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r')"
code="$(echo "$hdr" | head -n 1 | awk '{print $2}')"
[ "$code" = "302" ] || { echo "$hdr" | sed -n '1,25p'; fail "admin not 302"; }
loc="$(echo "$hdr" | awk -F': ' 'tolower($1)=="location"{print $2}' | head -n 1)"
[ -n "${loc:-}" ] || { echo "$hdr" | sed -n '1,25p'; fail "no Location header from /ui/admin"; }
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

[ -n "$TENANT_ID" ] || fail "could not parse tenantId from Location"
[ -n "$TENANT_KEY" ] || fail "could not parse k from Location"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

echo "==> [3] /ui/setup should be 200"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY")"
echo "status=$s3"
[ "$s3" = "200" ] || fail "setup not 200"

echo "==> [4] Generate Zapier Pack (dist)"
BASE_URL="$BASE_URL" TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" ./scripts/zapier-pack.sh >/dev/null
[ -f "dist/intake-guardian-agent/zapier_pack/ZAPIER_SETUP.md" ] || fail "zapier pack missing"
echo "✅ zapier pack ok"

echo
echo "✅ Phase31 smoke OK"
echo "Setup:"
echo "  $BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
echo "Zapier pack:"
echo "  dist/intake-guardian-agent/zapier_pack"
