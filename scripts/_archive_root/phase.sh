#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase30d OneShot (fix smoke-phase30 Location capture + stronger parsing) @ $(pwd)"
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase30d_${ts}"

[ -d "src" ] || { echo "ERROR: run inside repo root (src missing)"; exit 1; }
[ -d "scripts" ] || { echo "ERROR: run inside repo root (scripts missing)"; exit 1; }

echo "==> Backup -> $bak"
mkdir -p "$bak"
cp -R scripts "$bak/" 2>/dev/null || true

cat > scripts/smoke-phase30.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

fail(){ echo "FAIL: $*" >&2; exit 1; }

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${ADMIN_KEY:-}}"

[ -n "${ADMIN_KEY:-}" ] || fail "missing ADMIN_KEY (set ADMIN_KEY=... )"

echo "==> [0] health"
s0="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
[ "$s0" = "200" ] || fail "health not 200 (got $s0)"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui" || true)"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden (expected 404, got $s1)"

echo "==> [2] /ui/admin redirect (302 expected) + capture Location"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" || true)"
# normalize CRLF
hdr_n="$(printf "%s" "$hdr" | tr -d '\r')"

status="$(printf "%s" "$hdr_n" | head -n 1 | awk '{print $2}' | tr -d '[:space:]')"
[ "${status:-}" = "302" ] || {
  echo "---- debug headers ----"
  printf "%s\n" "$hdr_n" | head -n 30
  fail "/ui/admin not 302 (got ${status:-empty})"
}

loc="$(printf "%s\n" "$hdr_n" | awk 'BEGIN{IGNORECASE=1} /^location:/{sub(/^[Ll]ocation:[[:space:]]*/,""); print; exit}')"
loc="$(echo "${loc:-}" | tr -d '[:space:]')"

[ -n "${loc:-}" ] || {
  echo "---- debug headers ----"
  printf "%s\n" "$hdr_n" | head -n 50
  fail "no Location header from /ui/admin"
}

echo "Location=$loc"

# Build absolute URL if relative
final="$loc"
if [[ "$final" == /* ]]; then
  final="${BASE_URL%/}$final"
fi

# Extract tenantId and k from the Location query (bash-only)
# works for both relative and absolute URLs
q="${loc#*\?}"
TENANT_ID="$(printf "%s" "$q" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(printf "%s" "$q" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

# URL decode via python if available (optional)
if command -v python3 >/dev/null 2>&1; then
  TENANT_ID="$(python3 - <<PY
import urllib.parse
print(urllib.parse.unquote("${TENANT_ID}"))
PY
)"
  TENANT_KEY="$(python3 - <<PY
import urllib.parse
print(urllib.parse.unquote("${TENANT_KEY}"))
PY
)"
fi

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"
[ -n "${TENANT_ID:-}" ] || fail "could not parse tenantId from Location"
[ -n "${TENANT_KEY:-}" ] || fail "could not parse k from Location"

echo "==> [3] tickets should be 200"
ticketsUrl="${BASE_URL%/}/ui/tickets?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "$ticketsUrl" || true)"
echo "status=$s3"
[ "$s3" = "200" ] || fail "tickets not 200: $ticketsUrl"

echo "==> [4] export.csv should be 200"
exportUrl="${BASE_URL%/}/ui/export.csv?tenantId=${TENANT_ID}&k=${TENANT_KEY}"
s4="$(curl -sS -o /dev/null -w "%{http_code}" "$exportUrl" || true)"
echo "status=$s4"
[ "$s4" = "200" ] || fail "export not 200: $exportUrl"

echo "==> [5] /ui/setup should be 200 (optional)"
s5="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL%/}/ui/setup" || true)"
echo "status=$s5"
# allow 200 or 302 if you later decide to protect it
[ "$s5" = "200" ] || [ "$s5" = "302" ] || fail "/ui/setup not 200/302 (got $s5)"

echo
echo "✅ Phase30 smoke OK"
echo "Client UI:"
echo "  $ticketsUrl"
echo "Export CSV:"
echo "  $exportUrl"
echo "Setup:"
echo "  ${BASE_URL%/}/ui/setup"
BASH

chmod +x scripts/smoke-phase30.sh
echo "✅ wrote scripts/smoke-phase30.sh"

echo
echo "✅ Phase30d installed."
echo "Now run:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-phase30.sh"
