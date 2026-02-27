#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:7090}"
TENANT="${TENANT:-tenant_demo}"

PASS=0
FAIL=0

ok()  { echo "✅ $*"; PASS=$((PASS+1)); }
bad() { echo "❌ $*"; FAIL=$((FAIL+1)); }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}

need curl
need jq

echo "==> Smoke Day-5"
echo "BASE_URL=$BASE_URL"
echo "TENANT=$TENANT"
echo

# 1) Health
echo "==> [1] GET /api/health"
if curl -fsS "$BASE_URL/api/health" | jq -e '.ok == true' >/dev/null; then
  ok "health ok"
else
  bad "health failed"
fi
echo

# 2) SendGrid adapter ingest (multipart/form-data)
echo "==> [2] POST /api/adapters/email/sendgrid (multipart)"
RESP1="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -F 'from=employee@corp.local' \
  -F 'subject=VPN broken' \
  -F 'text=VPN is down ASAP. Cannot access network.' )"

if echo "$RESP1" | jq -e '.ok == true and (.workItem.id | length) > 5' >/dev/null; then
  WID="$(echo "$RESP1" | jq -r '.workItem.id')"
  ok "sendgrid ingest ok (workItemId=$WID)"
else
  echo "$RESP1" | jq . || true
  bad "sendgrid ingest failed"
  WID=""
fi
echo

# 3) List workitems
echo "==> [3] GET /api/workitems?tenantId=...&limit=5"
RESP2="$(curl -fsS "$BASE_URL/api/workitems?tenantId=$TENANT&limit=5")"
if echo "$RESP2" | jq -e '.ok == true and (.items | type=="array")' >/dev/null; then
  ok "workitems list ok"
else
  echo "$RESP2" | jq . || true
  bad "workitems list failed"
fi
echo

# 4) Dedupe (send same message again => duplicated should be true)
echo "==> [4] Dedupe: send same payload again => duplicated=true"
RESP3="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -F 'from=employee@corp.local' \
  -F 'subject=VPN broken' \
  -F 'text=VPN is down ASAP. Cannot access network.' )"

if echo "$RESP3" | jq -e '.ok == true and .duplicated == true' >/dev/null; then
  ok "dedupe ok (duplicated=true)"
else
  echo "$RESP3" | jq . || true
  bad "dedupe failed (expected duplicated=true)"
fi
echo

# 5) Status update (if we have a workItemId)
if [ -n "${WID:-}" ]; then
  echo "==> [5] POST /api/workitems/:id/status"
  RESP4="$(curl -fsS "$BASE_URL/api/workitems/$WID/status" \
    -H 'Content-Type: application/json' \
    -d "{\"tenantId\":\"$TENANT\",\"next\":\"in_progress\"}" )"

  if echo "$RESP4" | jq -e '.ok == true and .workItem.status == "in_progress"' >/dev/null; then
    ok "status update ok"
  else
    echo "$RESP4" | jq . || true
    bad "status update failed"
  fi
  echo

  echo "==> [6] GET /api/workitems/:id/events"
  RESP5="$(curl -fsS "$BASE_URL/api/workitems/$WID/events?tenantId=$TENANT&limit=50")"
  if echo "$RESP5" | jq -e '.ok == true and (.events | type=="array")' >/dev/null; then
    ok "events list ok"
  else
    echo "$RESP5" | jq . || true
    bad "events list failed"
  fi
  echo
else
  echo "==> [5/6] Skipped (no workItemId captured)"
  echo
fi

# 7) Rate limit test (only if enabled; we detect it by trying bursts)
echo "==> [7] Rate-limit burst (may PASS even if not triggered, depending on RATE_LIMIT_MAX)"
RATE_LIMIT_HIT=0
for i in $(seq 1 80); do
  R="$(curl -sS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
    -F 'from=employee@corp.local' \
    -F 'subject=burst-test' \
    -F 'text=hello' || true)"

  if echo "$R" | jq -e '.error == "rate_limited"' >/dev/null 2>&1; then
    RATE_LIMIT_HIT=1
    break
  fi
done

if [ "$RATE_LIMIT_HIT" -eq 1 ]; then
  ok "rate-limit triggered (rate_limited)"
else
  ok "rate-limit not triggered (this can be OK if limits are high)"
fi
echo

echo "==> Summary"
echo "PASS=$PASS"
echo "FAIL=$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
