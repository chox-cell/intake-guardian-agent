#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"
echo "BASE_URL=$BASE_URL"
[ -n "$ADMIN_KEY" ] || { echo "missing ADMIN_KEY"; exit 1; }
echo "==> headers for /ui/admin"
curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | tr -d '\r'
