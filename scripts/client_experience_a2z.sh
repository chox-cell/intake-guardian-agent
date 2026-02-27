#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
EMAIL="${EMAIL:-test+agency@local.dev}"
DATA_DIR="${DATA_DIR:-./data}"
LEADS="${LEADS:-./scripts/demo_leads.jsonl}"

echo "==> Client Experience A2Z"
echo "==> BASE_URL  = $BASE_URL"
echo "==> EMAIL     = $EMAIL"
echo "==> DATA_DIR  = $DATA_DIR"
echo "==> LEADS     = $LEADS"
echo

echo "==> 0) Health"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: /health => HTTP $code" >&2
  exit 1
fi
echo "OK: /health => 200"
echo

echo "==> 1) Request login link"
req_code="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/api/auth/request-link" \
  -H "content-type: application/json" \
  --data "{\"email\":\"$EMAIL\"}" || true)"
echo "request-link => HTTP $req_code"
if [ "$req_code" != "200" ]; then
  echo "FAIL: expected 200 from request-link" >&2
  exit 1
fi
echo

echo "==> 2) Read latest outbox email + extract verify URL"
MAIL="$(ls -1t "$DATA_DIR/outbox"/mail_*.txt 2>/dev/null | head -n 1 || true)"
if [ -z "${MAIL:-}" ]; then
  echo "FAIL: no outbox mail found in $DATA_DIR/outbox" >&2
  exit 1
fi
echo "OK: latest mail => $MAIL"

VERIFY_URL="$(rg -o 'http://127\.0\.0\.1:7090/api/auth/verify\?token=[A-Za-z0-9_-]+' "$MAIL" -o | head -n 1 || true)"
if [ -z "${VERIFY_URL:-}" ]; then
  # fallback: any /api/auth/verify link
  VERIFY_URL="$(rg -o '/api/auth/verify\?token=[A-Za-z0-9_-]+' "$MAIL" -o | head -n 1 || true)"
  if [ -n "${VERIFY_URL:-}" ] && [[ "$VERIFY_URL" != http* ]]; then
    VERIFY_URL="$BASE_URL$VERIFY_URL"
  fi
fi

if [ -z "${VERIFY_URL:-}" ]; then
  echo "FAIL: could not extract verify URL from outbox mail" >&2
  tail -n 30 "$MAIL" >&2 || true
  exit 1
fi
echo "OK: verify URL extracted (hidden)"

# sanitize any accidental "NNN:" prefix
VERIFY_URL="$(echo "$VERIFY_URL" | sed -E 's/^[0-9]+:\s*//')"
echo

echo "==> 3) Verify (follow redirects; capture final URL)"
WELCOME="$(curl -sS -L -o /dev/null -w "%{url_effective}" "$VERIFY_URL" || true)"
if [ -z "${WELCOME:-}" ] || [[ "$WELCOME" != *"/ui/welcome"* ]]; then
  echo "FAIL: verify did not end at /ui/welcome" >&2
  echo "Got: $WELCOME" >&2
  exit 1
fi
echo "OK: welcome => $WELCOME"

TENANT_ID="$(node -e 'const u=new URL(process.argv[1]); process.stdout.write(u.searchParams.get("tenantId")||"");' "$WELCOME")"
K="$(node -e 'const u=new URL(process.argv[1]); process.stdout.write(u.searchParams.get("k")||"");' "$WELCOME")"

if [ -z "${TENANT_ID:-}" ] || [ -z "${K:-}" ]; then
  echo "FAIL: could not extract tenantId/k from welcome URL" >&2
  echo "WELCOME: $WELCOME" >&2
  exit 1
fi

echo "OK: tenantId extracted"
echo "OK: k extracted (hidden)"
echo

echo "==> 4) Open Welcome UI (manual copy/paste)"
echo "$WELCOME"
echo

echo "==> 5) Send demo leads to webhook (with tenant auth)"
if [ ! -f "$LEADS" ]; then
  echo "FAIL: leads file not found: $LEADS" >&2
  exit 1
fi

TENANT_ID_ENC="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]||""))' "$TENANT_ID")"
K_ENC="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]||""))' "$K")"

i=0
while IFS= read -r line; do
  [ -z "${line:-}" ] && continue
  code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID_ENC&k=$K_ENC" \
    -H "content-type: application/json" \
    --data "$line" || true)"
  echo "lead[$i] => HTTP $code"
  i=$((i+1))
done < "$LEADS"
echo "OK: leads sent = $i"
echo

echo "==> 6) Open Pages"
DECISIONS="$BASE_URL/ui/decisions?tenantId=$TENANT_ID&k=$K"
TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$K"
SETUP="$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$K"
CSV="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$K"
ZIP="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$K"
PILOT="$BASE_URL/ui/pilot?tenantId=$TENANT_ID&k=$K"

echo "Welcome:   $WELCOME"
echo "Decisions: $DECISIONS"
echo "Tickets:   $TICKETS"
echo "Setup:     $SETUP"
echo "CSV:       $CSV"
echo "ZIP:       $ZIP"
echo "Pilot:     $PILOT"
echo

if command -v open >/dev/null 2>&1; then
  open "$WELCOME" || true
  open "$DECISIONS" || true
  open "$TICKETS" || true
  open "$SETUP" || true
  open "$CSV" || true
  open "$ZIP" || true
  open "$PILOT" || true
fi

echo "✅ DONE — Full client pilot experience completed."
