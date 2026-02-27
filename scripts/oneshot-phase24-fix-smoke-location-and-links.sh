#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts() { date -u +"%Y%m%d_%H%M%S"; }
BACK="__bak_phase24_$(ts)"
mkdir -p "$BACK/scripts"
cp -f scripts/smoke-ui.sh scripts/demo-keys.sh scripts/admin-link.sh 2>/dev/null || true
cp -f scripts/smoke-ui.sh "$BACK/scripts/" 2>/dev/null || true
cp -f scripts/demo-keys.sh "$BACK/scripts/" 2>/dev/null || true
cp -f scripts/admin-link.sh "$BACK/scripts/" 2>/dev/null || true

echo "==> Phase24 OneShot (fix Location parsing + stable links) @ $ROOT"
echo "✅ backup -> $BACK"

mkdir -p scripts

cat > scripts/_lib_http.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

# BASE_URL must be like: http://127.0.0.1:7090
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fetch headers safely (preserve CRLF removal)
http_headers() {
  local url="$1"
  curl -sS -D- -o /dev/null "$url" | tr -d '\r'
}

# Get HTTP status code (first line)
http_status() {
  local url="$1"
  http_headers "$url" | head -n 1 | awk '{print $2}'
}

# Extract Location header (case-insensitive)
http_location() {
  local url="$1"
  http_headers "$url" | awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^location:[[:space:]]*/,""); print; exit}'
}

# Turn relative Location into absolute URL
abs_url() {
  local loc="$1"
  if [[ "$loc" =~ ^https?:// ]]; then
    echo "$loc"
  else
    echo "${BASE_URL}${loc}"
  fi
}
BASH
chmod +x scripts/_lib_http.sh

cat > scripts/admin-link.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib_http.sh"

ADMIN_KEY="${ADMIN_KEY:-}"
[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY is required"

echo "==> Open admin autolink (will redirect to client UI)"
echo "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
BASH
chmod +x scripts/admin-link.sh

cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib_http.sh"

ADMIN_KEY="${ADMIN_KEY:-}"
[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY is required"

adminUrl="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"

echo "==> Open admin autolink (will redirect to client UI)"
echo "$adminUrl"

echo
echo "==> Resolve redirect -> final client link"
loc="$(http_location "$adminUrl" || true)"
[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"

final="$(abs_url "$loc")"
echo "✅ client link:"
echo "$final"

exportUrl="$(echo "$final" | sed 's|/ui/tickets|/ui/export.csv|')"
echo
echo "==> ✅ Export CSV"
echo "$exportUrl"
BASH
chmod +x scripts/demo-keys.sh

cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib_http.sh"

ADMIN_KEY="${ADMIN_KEY:-}"
[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY is required"

echo "==> [0] health"
s0="$(http_status "${BASE_URL}/health")"
[ "$s0" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(http_status "${BASE_URL}/ui")"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden"
echo "✅ /ui hidden"

echo "==> [2] /ui/admin redirect (302 expected)"
adminUrl="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
s2="$(http_status "$adminUrl")"
echo "status=$s2"
[ "$s2" = "302" ] || fail "expected 302 from /ui/admin"

loc="$(http_location "$adminUrl" || true)"
[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"

final="$(abs_url "$loc")"

echo "==> [3] follow redirect -> tickets should be 200"
s3="$(http_status "$final")"
echo "status=$s3"
[ "$s3" = "200" ] || fail "tickets not 200: $final"

exportUrl="$(echo "$final" | sed 's|/ui/tickets|/ui/export.csv|')"
echo "==> [4] export should be 200"
s4="$(http_status "$exportUrl")"
echo "status=$s4"
[ "$s4" = "200" ] || fail "export not 200: $exportUrl"

echo "✅ smoke ui ok"
echo "$final"
echo
echo "==> ✅ Export CSV"
echo "$exportUrl"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> Typecheck (skip if you don't have lint:types script)"
pnpm -s lint:types || true

echo
echo "✅ Phase24 installed."
echo "Now:"
echo "  1) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  3) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
