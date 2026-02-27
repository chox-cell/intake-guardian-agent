#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase25b OneShot (fix smoke Location + ensure smoke-webhook exists)"

mkdir -p scripts

# -------------------------
# Fix smoke-ui.sh (robust Location parsing)
# -------------------------
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*"; exit 1; }

echo "==> [0] health"
s0="$(curl -sS -D- "$BASE_URL/health" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s0:-}" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -D- "$BASE_URL/ui" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui not hidden (expected 404)"
echo "✅ /ui hidden"

echo "==> [2] /ui/admin redirect (302 expected)"
[ -n "${ADMIN_KEY:-}" ] || fail "missing ADMIN_KEY"
hdrs="$(mktemp)"
curl -sS -D "$hdrs" -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" || true
s2="$(head -n 1 "$hdrs" | awk '{print $2}')"
echo "status=$s2"
[ "${s2:-}" = "302" ] || { echo "---- headers ----"; cat "$hdrs"; fail "expected 302"; }

# Location (case-insensitive) + strip CR
loc="$(awk 'BEGIN{IGNORECASE=1} /^Location:/{sub(/\r/,""); print $2; exit}' "$hdrs")"
[ -n "${loc:-}" ] || { echo "---- headers ----"; cat "$hdrs"; fail "no Location header from /ui/admin"; }

final="$BASE_URL$loc"
echo "✅ Location: $loc"
echo "==> [3] follow redirect -> tickets should be 200"
s3="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s3"
[ "${s3:-}" = "200" ] || fail "tickets not 200: $final"

echo "==> [4] export should be 200"
# build export url from tickets url (replace /ui/tickets -> /ui/export.csv)
exportUrl="$(echo "$final" | sed 's#/ui/tickets#/ui/export.csv#')"
s4="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s4"
[ "${s4:-}" = "200" ] || fail "export not 200: $exportUrl"

echo "✅ smoke ui ok"
echo "$final"
echo "$exportUrl"
BASH
chmod +x scripts/smoke-ui.sh
echo "✅ wrote scripts/smoke-ui.sh"

# -------------------------
# Ensure smoke-webhook.sh exists (Phase25 real data)
# -------------------------
cat > scripts/smoke-webhook.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
TENANT_ID="${TENANT_ID:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-}"

fail(){ echo "❌ $*"; exit 1; }
[ -n "${TENANT_KEY:-}" ] || fail "missing TENANT_KEY. Use: TENANT_KEY=... TENANT_ID=... BASE_URL=..."

echo "==> [0] health"
s0="$(curl -sS -D- "$BASE_URL/health" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s0:-}" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] send webhook intake"
payload='{"title":"Webhook Ticket (real)","body":"Created via smoke-webhook","customer":{"name":"ACME Ops","email":"ops@acme.test","org":"ACME"},"meta":{"channel":"smoke"}}'
s1="$(curl -sS -D- -X POST \
  -H 'content-type: application/json' \
  -H "x-tenant-id: $TENANT_ID" \
  -H "x-tenant-key: $TENANT_KEY" \
  --data "$payload" \
  "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" \
  -o /tmp/ig_webhook.json | head -n 1 | awk '{print $2}')"

[ "${s1:-}" = "201" ] || { echo "---- body ----"; cat /tmp/ig_webhook.json || true; fail "webhook not 201 (got ${s1:-})"; }
echo "✅ webhook 201"

echo "==> [2] tickets UI should be 200"
ticketsUrl="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$TENANT_KEY"
s2="$(curl -sS -D- "$ticketsUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s2:-}" = "200" ] || fail "tickets ui not 200: $ticketsUrl"
echo "✅ tickets ui 200"

echo "==> [3] export should be 200"
exportUrl="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$TENANT_KEY"
s3="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${s3:-}" = "200" ] || fail "export not 200: $exportUrl"
echo "✅ export 200"

echo
echo "✅ smoke webhook ok"
echo "$ticketsUrl"
echo "$exportUrl"
BASH
chmod +x scripts/smoke-webhook.sh
echo "✅ wrote scripts/smoke-webhook.sh"

echo
echo "✅ Phase25b installed."
echo "Now run:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  TENANT_ID=... TENANT_KEY=... BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-webhook.sh"
