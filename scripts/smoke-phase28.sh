#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY. Use: ADMIN_KEY=... BASE_URL=... ./scripts/smoke-phase28.sh"

say "[0] health"
curl -sS "$BASE_URL/health" >/dev/null || fail "health not ok"
echo "✅ health ok"

say "[1] /ui hidden (404 expected)"
s1="$(curl -sS -D- -o /dev/null "$BASE_URL/ui" | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui not 404"

say "[2] /ui/admin redirect (302 expected) + capture Location"
headers="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
loc="$(echo "$headers" | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"
[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "${TENANT_ID:-}" ] || fail "empty TENANT_ID"
[ -n "${TENANT_KEY:-}" ] || fail "empty TENANT_KEY"
echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

final="$BASE_URL$loc"
say "[3] tickets should be 200"
s3="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s3"
[ "${s3:-}" = "200" ] || fail "tickets not 200: $final"

say "[4] export.csv should be 200"
exportUrl="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
s4="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s4"
[ "${s4:-}" = "200" ] || fail "export not 200: $exportUrl"

say "[5] evidence.zip should be 200"
zipUrl="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
s5="$(curl -sS -D- "$zipUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s5"
[ "${s5:-}" = "200" ] || fail "zip not 200: $zipUrl"

say "[6] webhook intake should be 201 and dedupe on repeat"
payload='{"source":"webhook","title":"Webhook intake","message":"hello","externalId":"demo-123","priority":"medium","data":{"a":1}}'
w1="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Id: demo-123" \
  -d "$payload")"
code1="$(echo "$w1" | tail -n 1)"
body1="$(echo "$w1" | sed '$d')"
echo "status=$code1"
[ "$code1" = "201" ] || fail "webhook not 201: $body1"
echo "$body1" | head -c 200; echo

w2="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Id: demo-123" \
  -d "$payload")"
code2="$(echo "$w2" | tail -n 1)"
body2="$(echo "$w2" | sed '$d')"
echo "status=$code2"
[ "$code2" = "201" ] || fail "webhook repeat not 201: $body2"
echo "$body2" | head -c 200; echo

say "[7] tickets page should still be 200 after webhook"
s7="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s7"
[ "${s7:-}" = "200" ] || fail "tickets not 200 after webhook"

echo
echo "✅ Phase28 smoke OK"
echo "Client UI:"
echo "  $final"
echo "Export CSV:"
echo "  $exportUrl"
echo "Evidence ZIP:"
echo "  $zipUrl"
