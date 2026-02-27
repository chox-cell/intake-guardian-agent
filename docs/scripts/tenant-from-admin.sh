#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

[ -n "$ADMIN_KEY" ] || { echo "❌ missing ADMIN_KEY"; exit 1; }

hdr="$(curl -sS -D- -o /dev/null "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}" | tr -d '\r')"
loc="$(printf "%s" "$hdr" | awk -F': ' 'tolower($1)=="location"{print $2; exit}')"

[ -n "${loc:-}" ] || { echo "❌ no Location from /ui/admin"; echo "$hdr" | head -n 30; exit 1; }

tenantId="$(printf "%s" "$loc" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
k="$(printf "%s" "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

# decode %xx using python if available, otherwise keep raw
if command -v python3 >/dev/null 2>&1; then
  tenantId="$(python3 - <<PY
import urllib.parse
print(urllib.parse.unquote("$tenantId"))
PY
)"
  k="$(python3 - <<PY
import urllib.parse
print(urllib.parse.unquote("$k"))
PY
)"
fi

echo "TENANT_ID=$tenantId"
echo "TENANT_KEY=$k"
echo "CLIENT_URL=${BASE_URL}${loc}"
