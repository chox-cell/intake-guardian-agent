#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
s0="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/health" || true)"
[ "$s0" = "200" ] || fail "health not 200 (got $s0)"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/ui" || true)"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden (expected 404)"

echo "==> [2] /ui/admin redirect (302 expected) + capture Location"
[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" || true)"

# show debug if needed
if ! echo "$hdr" | head -n 1 | grep -q " 302 "; then
  echo "---- debug headers ----"
  echo "$hdr" | head -n 25
fi

# capture Location safely
loc="$(printf '%s\n' "$hdr" | awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r$/,""); print $0; exit}')"
[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"

# loc is like: "Location: /ui/tickets?tenantId=tenant_demo&k=...."
loc="${loc#Location: }"
echo "Location=$loc"

# Extract query string
q="${loc#*\?}"
# Parse tenantId even if first or later
TENANT_ID="$(printf '%s' "$q" | sed -n 's/^tenantId=\([^&]*\).*/\1/p; s/.*[&?]tenantId=\([^&]*\).*/\1/p' | head -n 1)"
TENANT_KEY="$(printf '%s' "$q" | sed -n 's/^k=\([^&]*\).*/\1/p; s/.*[&?]k=\([^&]*\).*/\1/p' | head -n 1)"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"
[ -n "${TENANT_ID:-}" ] || fail "could not parse tenantId from Location"
[ -n "${TENANT_KEY:-}" ] || fail "could not parse k from Location"

tickets="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
exportCsv="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
evidenceZip="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> [3] tickets should be 200"
s3="$(curl -sS -o /dev/null -w '%{http_code}' "$tickets" || true)"
echo "status=$s3"
[ "$s3" = "200" ] || fail "tickets not 200: $tickets"

echo "==> [4] export.csv should be 200"
s4="$(curl -sS -o /dev/null -w '%{http_code}' "$exportCsv" || true)"
echo "status=$s4"
[ "$s4" = "200" ] || fail "export.csv not 200: $exportCsv"

# evidence.zip might not exist in older phases; only check if endpoint responds (200/404 acceptable)
echo "==> [5] evidence.zip should be 200 (or 404 if not shipped yet)"
s5="$(curl -sS -o /dev/null -w '%{http_code}' "$evidenceZip" || true)"
echo "status=$s5"
if [ "$s5" != "200" ] && [ "$s5" != "404" ]; then
  fail "evidence.zip unexpected status $s5: $evidenceZip"
fi

echo
echo "✅ Phase30 smoke OK"
echo "Client UI:"
echo "  $tickets"
echo "Export CSV:"
echo "  $exportCsv"
echo "Evidence ZIP:"
echo "  $evidenceZip"
