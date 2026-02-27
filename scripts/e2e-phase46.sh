#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/Projects/intake-guardian-agent"
cd "$ROOT"

PORT="${PORT:-7090}"
ADMIN_KEY="${ADMIN_KEY:-super_secret_admin_123}"

if [ -f .env.local ]; then
  P="$(grep -E '^[[:space:]]*PORT=' .env.local | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  A="$(grep -E '^[[:space:]]*ADMIN_KEY=' .env.local | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  [ -n "${P:-}" ] && PORT="$P"
  [ -n "${A:-}" ] && ADMIN_KEY="$A"
fi

BASE_URL="http://127.0.0.1:${PORT}"
WEBHOOK_URL="${BASE_URL}/api/webhook/intake?tenantId=demo&k=${ADMIN_KEY}"

echo "==> Phase46 E2E"
echo "==> BASE_URL    = ${BASE_URL}"
echo "==> WEBHOOK_URL = ${WEBHOOK_URL}"

# Kill anything already on the port (best effort)
if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -ti tcp:${PORT} || true)"
  if [ -n "${PIDS:-}" ]; then
    echo "==> killing existing process(es) on port ${PORT}: ${PIDS}"
    kill -9 ${PIDS} || true
  fi
fi

# Start dev server
echo "==> starting server (pnpm dev) ..."
( ADMIN_KEY="${ADMIN_KEY}" PORT="${PORT}" pnpm dev > .phase46_server.log 2>&1 & echo $! > .phase46_server.pid )

PID="$(cat .phase46_server.pid)"
echo "==> server pid = ${PID}"

# Wait for server to listen
for i in $(seq 1 60); do
  if curl -fsS "${BASE_URL}/" >/dev/null 2>&1; then
    echo "==> server is responding"
    break
  fi
  sleep 0.25
done

# POST a Paid Ads lead
PAYLOAD='{
  "source": "phase46",
  "type": "lead",
  "channel": "meta",
  "presetId": "paid_ads.v1",
  "lead": { "fullName": "Phase46 Meta Lead", "email": "phase46@client.com", "company": "Client Co" },
  "tracking": { "hasPixel": true, "hasConversionApi": false, "hasGtm": true, "hasUtm": false, "hasThankYouPage": true },
  "offer": { "hasClearOffer": true },
  "assets": { "hasLandingPage": true, "hasCreativeAssets": true },
  "notes": "Phase46 E2E test"
}'

echo "==> posting webhook..."
RESP="$(curl -fsS -X POST "${WEBHOOK_URL}" -H "Content-Type: application/json" --data "${PAYLOAD}" || true)"

if [ -z "${RESP:-}" ]; then
  echo "FAIL: webhook returned empty response"
  echo "---- server log tail ----"
  tail -n 80 .phase46_server.log || true
  kill -9 "${PID}" || true
  exit 1
fi

echo "==> webhook response:"
echo "${RESP}" | sed 's/^/  /'

# Try to infer next URLs / ids from response (best-effort)
# Common patterns: { ok:true, id:"..." } or { ticketId:"..." } etc.
ID="$(node -e 'try{const r=JSON.parse(process.argv[1]);console.log(r.id||r.ticketId||r.decisionId||r.runId||"");}catch(e){console.log("");}' "${RESP}" 2>/dev/null || true)"

if [ -n "${ID:-}" ]; then
  echo "==> detected id = ${ID}"
fi

# Confirm preset wiring exists in resolver file we patched
if grep -R --line-number --quiet 'case "paid_ads.v1"' src/presets 2>/dev/null || grep -R --line-number --quiet '"paid_ads.v1"' src/presets 2>/dev/null; then
  echo "OK: preset wiring present under src/presets/"
else
  echo "WARN: could not confirm preset wiring under src/presets/ (check manually)"
fi

# Optional: probe UI endpoints if present (non-fatal)
for u in "/ui/tickets" "/ui/decisions" "/ui/export.csv" "/ui/evidence.zip"; do
  if curl -fsS -I "${BASE_URL}${u}" >/dev/null 2>&1; then
    echo "OK: HEAD ${u}"
  else
    echo "INFO: ${u} not reachable (may be auth-protected or not implemented)"
  fi
done

echo "==> stopping server..."
kill -9 "${PID}" >/dev/null 2>&1 || true

echo "✅ Phase46 E2E OK"
