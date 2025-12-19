#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:7090}"
TENANT="${TENANT:-tenant_demo}"
TENANT_KEY="${TENANT_KEY:-dev_key_123}"

PASS=0
FAIL=0

ok()  { echo "✅ $*"; PASS=$((PASS+1)); }
bad() { echo "❌ $*"; FAIL=$((FAIL+1)); }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }
need curl
need jq
need date

TS="$(date +%s)"
SUBJECT_UNIQ="smoke-tenantkeys-$TS"
BODY_UNIQ="VPN is down ASAP. Cannot access network. smoke_ts=$TS"

echo "==> Smoke Day-5 (with Tenant Keys)"
echo "BASE_URL=$BASE_URL"
echo "TENANT=$TENANT"
echo "TENANT_KEY=${TENANT_KEY:0:3}***"
echo "SUBJECT=$SUBJECT_UNIQ"
echo

# 1) Health (no key)
echo "==> [1] GET /api/health"
if curl -fsS "$BASE_URL/api/health" | jq -e '.ok == true' >/dev/null; then
  ok "health ok"
else
  bad "health failed"
fi
echo

# 2) Tenant key gate (expect 401/403 without key)
echo "==> [2] Tenant key gate (expect 401/403 without x-tenant-key)"
HTTP_CODE="$(curl -sS -o /tmp/ig_tmp.json -w "%{http_code}" "$BASE_URL/api/workitems?tenantId=$TENANT&limit=1" || true)"
if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
  ok "tenant gate enforced (http=$HTTP_CODE)"
else
  echo "http=$HTTP_CODE body:"
  cat /tmp/ig_tmp.json || true
  bad "tenant gate NOT enforced (expected 401/403)"
fi
echo

# 3) Ingest NEW unique ticket (with key)
echo "==> [3] POST /api/adapters/email/sendgrid (unique ticket)"
RESP1="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F "subject=$SUBJECT_UNIQ" \
  -F "text=$BODY_UNIQ" )"

if echo "$RESP1" | jq -e '.ok == true and (.workItem.id | length) > 5' >/dev/null; then
  WID="$(echo "$RESP1" | jq -r '.workItem.id')"
  ok "ingest ok (workItemId=$WID)"
else
  echo "$RESP1" | jq . || true
  bad "ingest failed"
  WID=""
fi
echo

# 4) List workitems WITH key
echo "==> [4] GET /api/workitems (with key)"
RESP2="$(curl -fsS "$BASE_URL/api/workitems?tenantId=$TENANT&limit=5" -H "x-tenant-key: $TENANT_KEY")"
if echo "$RESP2" | jq -e '.ok == true and (.items | type=="array")' >/dev/null; then
  ok "workitems list ok"
else
  echo "$RESP2" | jq . || true
  bad "workitems list failed"
fi
echo

# 5) Dedupe check (send same subject+body again => duplicated should be true)
echo "==> [5] Dedupe: same payload again => duplicated=true"
RESP3="$(curl -fsS "$BASE_URL/api/adapters/email/sendgrid?tenantId=$TENANT" \
  -H "x-tenant-key: $TENANT_KEY" \
  -F 'from=employee@corp.local' \
  -F "subject=$SUBJECT_UNIQ" \
  -F "text=$BODY_UNIQ" )"

if echo "$RESP3" | jq -e '.ok == true and .duplicated == true' >/dev/null; then
  ok "dedupe ok (duplicated=true)"
else
  echo "$RESP3" | jq . || true
  bad "dedupe failed"
fi
echo

# 6) Status transition test (on fresh item): new -> in_progress
if [ -n "${WID:-}" ]; then
  echo "==> [6] POST /api/workitems/:id/status (new->in_progress)"
  RESP4="$(curl -fsS "$BASE_URL/api/workitems/$WID/status" \
    -H 'Content-Type: application/json' \
    -H "x-tenant-key: $TENANT_KEY" \
    -d "{\"tenantId\":\"$TENANT\",\"next\":\"in_progress\"}" )"

  if echo "$RESP4" | jq -e '.ok == true and .workItem.status == "in_progress"' >/dev/null; then
    ok "status update ok"
  else
    echo "$RESP4" | jq . || true
    bad "status update failed"
  fi
  echo

  echo "==> [7] GET /api/workitems/:id/events (with key)"
  RESP5="$(curl -fsS "$BASE_URL/api/workitems/$WID/events?tenantId=$TENANT&limit=50" -H "x-tenant-key: $TENANT_KEY")"
  if echo "$RESP5" | jq -e '.ok == true and (.events | type=="array")' >/dev/null; then
    ok "events list ok"
  else
    echo "$RESP5" | jq . || true
    bad "events list failed"
  fi
  echo
else
  echo "==> [6/7] Skipped (no workItemId captured)"
  echo
fi

echo "==> Summary"
echo "PASS=$PASS"
echo "FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
