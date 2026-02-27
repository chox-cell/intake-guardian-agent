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
