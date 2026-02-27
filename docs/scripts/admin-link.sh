#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib_http.sh"

ADMIN_KEY="${ADMIN_KEY:-}"
[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY is required"

echo "==> Open admin autolink (will redirect to client UI)"
echo "${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
