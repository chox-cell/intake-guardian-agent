#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "❌ $*" >&2; exit 1; }
say(){ echo "==> $*"; }

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${ADMIN_KEY:-}}"

[ -n "${ADMIN_KEY:-}" ] || fail "missing ADMIN_KEY. Example: ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/smoke-phase27.sh"

say "[0] health"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/health")"
echo "status=$code"
[ "$code" = "200" ] || fail "health not 200"

say "[1] /ui hidden (404 expected)"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/ui")"
echo "status=$code"
[ "$code" = "404" ] || fail "/ui should be hidden (404)"

say "[2] /ui/admin redirect (302 expected) + capture Location"
loc="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" \
  | awk -F': ' 'tolower($1)=="location"{print $2}' | tr -d '\r')"

[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "${TENANT_ID:-}" ] || fail "empty TENANT_ID"
[ -n "${TENANT_KEY:-}" ] || fail "empty TENANT_KEY"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

say "[3] tickets should be 200"
tickets_url="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$tickets_url")"
echo "status=$code"
[ "$code" = "200" ] || fail "tickets not 200: $tickets_url"

say "[4] export.csv should be 200"
export_url="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$export_url")"
echo "status=$code"
[ "$code" = "200" ] || fail "export.csv not 200: $export_url"

say "[5] webhook intake should be 201 (creates/ dedupes ticket)"
# Use existing smoke-webhook.sh if present, else do direct POST
if [ -x "./scripts/smoke-webhook.sh" ]; then
  TENANT_ID="$TENANT_ID" TENANT_KEY="$TENANT_KEY" BASE_URL="$BASE_URL" ./scripts/smoke-webhook.sh
else
  body='{"source":"phase27_smoke","title":"IT Support Request","summary":"Cannot login","severity":"medium","email":"user@example.com","ts":"'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'"}'
  code="$(curl -sS -o /tmp/phase27_webhook.json -w '%{http_code}' \
    -H 'content-type: application/json' \
    -H "x-tenant-id: $TENANT_ID" \
    -H "x-tenant-key: $TENANT_KEY" \
    -d "$body" \
    "$BASE_URL/api/webhook/intake")"
  echo "status=$code"
  cat /tmp/phase27_webhook.json || true
  [ "$code" = "201" ] || fail "webhook not 201"
fi

say "[6] tickets page should still be 200 after webhook"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$tickets_url")"
echo "status=$code"
[ "$code" = "200" ] || fail "tickets not 200 after webhook"

echo
echo "✅ Phase27 smoke OK"
echo "Client UI:"
echo "  $tickets_url"
echo "Export CSV:"
echo "  $export_url"
