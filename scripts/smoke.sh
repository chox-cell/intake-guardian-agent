#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-7090}"
BASE="http://localhost:${PORT}/api"
TENANT="tenant_demo"

echo "[1] health..."
# Updated to match the actual route: /health (not /api/health)
curl -s "http://localhost:${PORT}/health" | grep -q '"ok":true' && echo "OK"

echo "[2] intake create..."
OUT=$(curl -s "${BASE}/intake" \
  -H "Content-Type: application/json" \
  -d "{
    \"tenantId\":\"${TENANT}\",
    \"source\":\"email\",
    \"sender\":\"employee@corp.local\",
    \"subject\":\"VPN broken\",
    \"body\":\"VPN is down ASAP. Cannot access network.\",
    \"receivedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }")

echo "$OUT" | grep -q '"ok":true' && echo "OK"

ID=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.workItem.id);});')

echo "[3] list..."
curl -s "${BASE}/workitems?tenantId=${TENANT}&limit=5" | grep -q "$ID" && echo "OK"

echo "[4] events..."
curl -s "${BASE}/workitems/${ID}/events?tenantId=${TENANT}" | grep -q '"created"' && echo "OK"

echo "[5] status transition..."
curl -s "${BASE}/workitems/${ID}/status" \
  -H "Content-Type: application/json" \
  -d "{\"tenantId\":\"${TENANT}\",\"next\":\"in_progress\"}" | grep -q '"ok":true' && echo "OK"

echo "SMOKE DONE ✅"
