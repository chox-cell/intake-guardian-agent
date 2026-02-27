#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
echo "==> Phase16c OneShot (fix export URL escaping in bash scripts) @ $ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase16c_${ts}"
mkdir -p "$bak"
cp -R scripts "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak/scripts"

cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-dev_admin_key_123}"

clean_url() {
  # turns http:\/\/127.0.0.1:7090\/ui\/export.csv -> http://127.0.0.1:7090/ui/export.csv
  echo "$1" | sed -E 's#\\/#/#g'
}

echo "==> Open admin autolink (will redirect to client UI)"
admin_url="$BASE_URL/ui/admin?admin=$ADMIN_KEY"
echo "$admin_url"
echo

echo "==> Resolve redirect -> final client link"
# follow redirects and print final effective URL
final="$(curl -sS -L -o /dev/null -w '%{url_effective}' "$admin_url" | tr -d '\r')"
final="$(clean_url "$final")"
echo "✅ client link:"
echo "$final"
echo

# Build export link from tenantId + k
tenantId="$(echo "$final" | sed -nE 's/.*[?&]tenantId=([^&]+).*/\1/p')"
k="$(echo "$final" | sed -nE 's/.*[?&]k=([^&]+).*/\1/p')"

if [[ -z "${tenantId:-}" || -z "${k:-}" ]]; then
  echo "❌ could not parse tenantId/k from: $final" >&2
  exit 1
fi

export_url="$BASE_URL/ui/export.csv?tenantId=$tenantId&k=$k"
export_url="$(clean_url "$export_url")"

echo "==> ✅ Export CSV"
echo "$export_url"
BASH
chmod +x scripts/demo-keys.sh
echo "✅ wrote scripts/demo-keys.sh"

cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-dev_admin_key_123}"

clean_url() { echo "$1" | sed -E 's#\\/#/#g'; }
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/health" || true)"
[[ "$code" == "200" ]] || fail "health not 200 (got $code)"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/ui" || true)"
echo "status=$code"
[[ "$code" == "404" ]] || fail "/ui must be hidden (expected 404, got $code)"

echo "==> [2] /ui/admin redirect (302 expected)"
admin_url="$BASE_URL/ui/admin?admin=$ADMIN_KEY"
code="$(curl -sS -o /dev/null -w '%{http_code}' -I "$admin_url" || true)"
echo "status=$code"
[[ "$code" == "302" || "$code" == "200" ]] || fail "expected 302/200 on /ui/admin, got $code"

echo "==> [3] follow redirect -> tickets should be 200"
final="$(curl -sS -L -o /dev/null -w '%{url_effective}' "$admin_url" | tr -d '\r')"
final="$(clean_url "$final")"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$final" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "tickets not 200 (got $code) | $final"

tenantId="$(echo "$final" | sed -nE 's/.*[?&]tenantId=([^&]+).*/\1/p')"
k="$(echo "$final" | sed -nE 's/.*[?&]k=([^&]+).*/\1/p')"
[[ -n "${tenantId:-}" && -n "${k:-}" ]] || fail "could not parse tenantId/k from $final"

echo "==> [4] export should be 200"
export_url="$BASE_URL/ui/export.csv?tenantId=$tenantId&k=$k"
export_url="$(clean_url "$export_url")"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$export_url" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "expected 200 on export: $export_url"

echo "✅ smoke ui ok"
echo "$final"
BASH
chmod +x scripts/smoke-ui.sh
echo "✅ wrote scripts/smoke-ui.sh"

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase16c installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
