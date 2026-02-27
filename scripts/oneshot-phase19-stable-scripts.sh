#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase19_${ts}"
mkdir -p "$bak"
cp -R scripts "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak"

mkdir -p scripts

# ---------------------------
# scripts/demo-keys.sh (bash-only, no escaping)
# ---------------------------
cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "${ADMIN_KEY}" ]]; then
  echo "FAIL: ADMIN_KEY missing"
  echo "Example:"
  echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
  exit 1
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> Open admin autolink (stable demo tenant)"
echo "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
echo

# Fetch headers only (no follow) and extract Location
hdr="$(curl -sS -D - -o /dev/null "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" || true)"
loc="$(printf "%s" "$hdr" | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r')"

if [[ -z "$loc" ]]; then
  echo "---- debug headers ----"
  echo "$hdr"
  fail "no redirect location from /ui/admin"
fi

# Normalize to absolute URL
if [[ "$loc" =~ ^https?:// ]]; then
  final="$loc"
else
  final="${BASE_URL}${loc}"
fi

echo "==> Resolve redirect -> final client link"
echo "✅ client link:"
echo "$final"
echo

export_url="$(printf '%s' "$final" | sed 's|/ui/tickets|/ui/export.csv|')"
echo "==> ✅ Export CSV"
echo "$export_url"
BASH
chmod +x scripts/demo-keys.sh
echo "✅ wrote scripts/demo-keys.sh"

# ---------------------------
# scripts/smoke-ui.sh (bash-only, stable parsing)
# ---------------------------
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "${ADMIN_KEY}" ]]; then
  echo "FAIL: ADMIN_KEY missing"
  echo "Example:"
  echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
  exit 1
fi

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
code="$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" || true)"
[[ "$code" == "200" ]] || fail "health expected 200, got $code"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
code="$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/ui" || true)"
echo "status=$code"
[[ "$code" == "404" ]] || fail "/ui expected 404, got $code"

echo "==> [2] /ui/admin redirect (302 expected)"
hdr="$(curl -sS -D - -o /dev/null "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" || true)"
code="$(printf "%s" "$hdr" | head -n1 | awk '{print $2}' || true)"
echo "status=$code"
[[ "$code" == "302" ]] || { echo "---- debug headers ----"; echo "$hdr"; fail "expected 302"; }

redirect_url="$(printf "%s" "$hdr" | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -n1 | tr -d '\r')"
[[ -n "$redirect_url" ]] || { echo "---- debug headers ----"; echo "$hdr"; fail "no redirect_url"; }

if [[ "$redirect_url" =~ ^https?:// ]]; then
  final="$redirect_url"
else
  final="${BASE_URL}${redirect_url}"
fi

echo "==> [3] follow redirect -> tickets should be 200"
code="$(curl -s -o /dev/null -w "%{http_code}" "$final" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "tickets expected 200, got $code ($final)"

echo "==> [4] export should be 200"
export_url="$(printf '%s' "$final" | sed 's|/ui/tickets|/ui/export.csv|')"
code="$(curl -s -o /dev/null -w "%{http_code}" "$export_url" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "export expected 200, got $code ($export_url)"

echo "✅ smoke ui ok"
echo "$final"
BASH
chmod +x scripts/smoke-ui.sh
echo "✅ wrote scripts/smoke-ui.sh"

echo "==> [3] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase19 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
