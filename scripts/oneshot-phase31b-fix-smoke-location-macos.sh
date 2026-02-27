#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase31b OneShot (fix Location parsing on macOS for smoke scripts)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -d "scripts" ] || { echo "ERROR: scripts/ missing (run inside repo root)"; exit 1; }

TS="$(date +%Y%m%d_%H%M%S)"
mkdir -p "__bak_phase31b_${TS}"
for f in scripts/smoke-phase31.sh scripts/smoke-phase34.sh scripts/smoke-phase34-debug.sh; do
  if [ -f "$f" ]; then
    cp "$f" "__bak_phase31b_${TS}/$(basename "$f")"
  fi
done
echo "✅ backup -> __bak_phase31b_${TS}"

# -------------------------
# smoke-phase31.sh (robust)
# -------------------------
cat > scripts/smoke-phase31.sh <<'BASH'
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
BASH
chmod +x scripts/smoke-phase31.sh
echo "✅ wrote scripts/smoke-phase31.sh"

# -------------------------
# smoke-phase34.sh (robust + evidence.zip + zapier pack)
# -------------------------
cat > scripts/smoke-phase34.sh <<'BASH'
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
BASH
chmod +x scripts/smoke-phase34.sh
echo "✅ wrote scripts/smoke-phase34.sh"

# -------------------------
# debug helper
# -------------------------
cat > scripts/smoke-phase34-debug.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"
echo "BASE_URL=$BASE_URL"
[ -n "$ADMIN_KEY" ] || { echo "missing ADMIN_KEY"; exit 1; }
echo "==> headers for /ui/admin"
curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r'
BASH
chmod +x scripts/smoke-phase34-debug.sh
echo "✅ wrote scripts/smoke-phase34-debug.sh"

echo
echo "✅ Phase31b installed."
echo "Now do this in TWO terminals:"
echo "  (A) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  (B) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase31.sh"
echo "  (B) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase34.sh"
