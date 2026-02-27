#!/usr/bin/env bash
set -euo pipefail

say(){ echo "==> $*"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -d "scripts" ] || { echo "ERROR: scripts/ missing. Run inside repo root."; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase34b_${TS}"
say "Backup -> $BAK"
mkdir -p "$BAK/scripts"
cp -f scripts/smoke-phase34.sh "$BAK/scripts/" 2>/dev/null || true
cp -f scripts/smoke-phase33.sh "$BAK/scripts/" 2>/dev/null || true

say "Write scripts/smoke-phase34-debug.sh"
cat > scripts/smoke-phase34-debug.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

echo "BASE_URL=$BASE_URL"
[ -n "$ADMIN_KEY" ] || { echo "❌ missing ADMIN_KEY"; exit 1; }

echo "==> headers for /ui/admin"
curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=${ADMIN_KEY}" | sed -n '1,40p' | sed 's/\r$//'
BASH
chmod +x scripts/smoke-phase34-debug.sh

say "Write scripts/smoke-phase34.sh (robust Location parsing + CRLF safe)"
cat > scripts/smoke-phase34.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "FAIL: $*" >&2; exit 1; }

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY"

echo "==> health"
curl -sS "$BASE_URL/health" >/dev/null 2>&1 || fail "health failed"

echo "==> /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not 404"

echo "==> /ui/admin redirect (302 expected) + capture Location"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=${ADMIN_KEY}" | sed 's/\r$//')"

# Extract Location (case-insensitive), strip "Location: " prefix
loc="$(printf "%s\n" "$hdr" | awk 'BEGIN{IGNORECASE=1} /^location:/{sub(/^location:[[:space:]]*/,"",$0); print; exit}')"

if [ -z "${loc:-}" ]; then
  echo "---- debug headers ----"
  printf "%s\n" "$hdr" | sed -n '1,40p'
  fail "no Location header from /ui/admin"
fi

echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"

[ -n "${TENANT_ID:-}" ] || fail "could not parse tenantId from Location"
[ -n "${TENANT_KEY:-}" ] || fail "could not parse k from Location"

TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
CSV="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
ZIP="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$TENANT_KEY"
SETUP="$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"

echo "==> tickets should be 200"
s2="$(curl -sS -o /dev/null -w "%{http_code}" "$TICKETS")"
echo "status=$s2"
[ "$s2" = "200" ] || fail "tickets not 200: $TICKETS"

echo "==> export.csv should be 200"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "$CSV")"
echo "status=$s3"
[ "$s3" = "200" ] || fail "csv not 200: $CSV"

echo "==> evidence.zip should be 200"
s4="$(curl -sS -o /dev/null -w "%{http_code}" "$ZIP")"
echo "status=$s4"
[ "$s4" = "200" ] || fail "zip not 200: $ZIP"

echo "==> zapier template pack (must produce onboarding)"
if [ -x "./scripts/zapier-template-pack.sh" ]; then
  ./scripts/zapier-template-pack.sh >/dev/null 2>&1 || fail "zapier-template-pack.sh failed"
else
  fail "missing scripts/zapier-template-pack.sh"
fi

# Best-effort checks (don’t hard-fail if your pack path differs)
if [ -f "dist/zapier-template-pack/CLIENT_ONBOARDING.md" ]; then
  echo "✅ pack ok (CLIENT_ONBOARDING.md found)"
else
  echo "⚠️ pack ran, but CLIENT_ONBOARDING.md not found at dist/zapier-template-pack/ (check your pack output path)"
fi

echo
echo "✅ Phase34 smoke OK"
echo "Client:"
echo "  $TICKETS"
echo "Setup:"
echo "  $SETUP"
echo "Export CSV:"
echo "  $CSV"
echo "Evidence ZIP:"
echo "  $ZIP"
BASH
chmod +x scripts/smoke-phase34.sh

echo
echo "✅ Phase34b installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase34.sh"
echo "If it fails again, run:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase34-debug.sh"
