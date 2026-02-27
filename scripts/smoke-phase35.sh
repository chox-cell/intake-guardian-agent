#!/usr/bin/env bash
set -e
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:?missing ADMIN_KEY}"
curl -fsS "$BASE_URL/health" >/dev/null
curl -fsSI "$BASE_URL/ui/start?adminKey=$ADMIN_KEY" | grep -q 302
echo "SMOKE OK"
