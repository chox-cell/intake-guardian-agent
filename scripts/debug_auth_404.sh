#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> grep request-link variants"
rg -n "request-link|request_link|requestLink" src || true
echo

echo "==> grep authRouter mounts"
rg -n 'authRouter\(|use\("\/api\/auth"|\/api\/auth' src/api/routes.ts src/server.ts src/api/*.ts || true
echo

echo "==> runtime probes"
BASE="http://127.0.0.1:7090"
set +e
curl -i "$BASE/api/auth" | head -n 20
echo
curl -i "$BASE/api/auth/request-link" | head -n 20
echo
curl -i -X POST "$BASE/api/auth/request-link" -H 'content-type: application/json' --data '{"email":"test@x.dev"}' | head -n 20
set -e
echo
echo "DONE"
