#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing_$1" >&2; exit 1; }; }
need curl

echo "==> health"
curl -i "$BASE_URL/api/health" | sed -n '1,30p'

echo
echo "==> candidate routes (HEAD/GET quick peek)"
for p in \
  "/api/admin/tenants/create" \
  "/api/admin/tenants" \
  "/api/tenants" \
  "/api/admin/tenants/list" \
  "/api/admin/tenants/rotate"
do
  echo "-- $p"
  curl -sSI "$BASE_URL$p" | sed -n '1,10p' || true
  echo
done
