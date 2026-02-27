#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
EMAIL="${EMAIL:-test+agency@local.dev}"
DATA_DIR="${DATA_DIR:-./data}"
LEADS_FILE="${LEADS_FILE:-./scripts/demo_leads.jsonl}"

echo "==> Agency Pilot Experience Runner"
echo "==> BASE_URL  = $BASE_URL"
echo "==> EMAIL     = $EMAIL"
echo "==> DATA_DIR  = $DATA_DIR"
echo "==> LEADS     = $LEADS_FILE"
echo

# 0) health
code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: server not healthy on $BASE_URL (got HTTP $code). Start server: pnpm dev" >&2
  exit 1
fi
echo "OK: /health => 200"
echo

# 1) Request login link (writes outbox in dev)
echo "==> 1) Request login link"
code="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/api/auth/request-link" \
  -H "content-type: application/json" \
  --data "{\"email\":\"$EMAIL\"}" || true)"
echo "request-link => HTTP $code"
if [ "$code" != "200" ]; then
  echo "FAIL: expected 200 from /api/auth/request-link" >&2
  exit 2
fi

# 2) Find latest outbox mail and extract verify URL
echo
echo "==> 2) Read latest outbox email + extract verify URL"
if [ ! -d "$DATA_DIR/outbox" ]; then
  echo "FAIL: $DATA_DIR/outbox not found. Did server write outbox?" >&2
  exit 3
fi

mail="$(ls -1t "$DATA_DIR/outbox"/mail_*.txt 2>/dev/null | head -n 1 || true)"
if [ -z "${mail:-}" ]; then
  echo "FAIL: no outbox mail found in $DATA_DIR/outbox" >&2
  exit 4
fi
echo "OK: latest mail => $mail"

# Extract first http(s) URL (verify link)
verify_url="$(rg -n 'https?://[^ ]+' "$mail" | head -n 1 | sed -E 's/^.*(https?:\/\/[^ ]+).*$/\1/' || true)"
if [ -z "${verify_url:-}" ]; then
  # fallback: sometimes link is on its own line without schema assumptions
  verify_url="$(cat "$mail" | rg -o 'https?://[^ ]+' | head -n 1 || true)"
fi
if [ -z "${verify_url:-}" ]; then
  echo "FAIL: could not find verify URL in outbox mail." >&2
  echo "TIP: open the mail file and copy link manually:" >&2
  echo "     open \"$mail\"" >&2
  exit 5
fi

echo "OK: verify URL (hidden)"
# Do NOT print token URL (privacy). We'll just hit it.
echo

# 3) Hit verify link (should redirect to /ui/welcome)
echo "==> 3) Verify (expect redirect to /ui/welcome)"
loc="$(curl -sS -o /dev/null -D - "$verify_url" | rg -i '^location:' | head -n 1 | sed -E 's/location:\s*//I' | tr -d '\r' || true)"
if [ -z "${loc:-}" ]; then
  echo "FAIL: expected Location header from verify endpoint." >&2
  exit 6
fi
echo "OK: redirect => $loc"

# Normalize welcome URL
if [[ "$loc" =~ ^/ ]]; then
  welcome="$BASE_URL$loc"
else
  welcome="$loc"
fi
echo "OK: welcome => $welcome"
echo

# 4) Open Welcome page (macOS)
if command -v open >/dev/null 2>&1; then
  echo "==> 4) Opening Welcome UI in browser"
  open "$welcome" || true
else
  echo "==> 4) Open this in browser:"
  echo "$welcome"
fi

# 5) Extract tenantId + k from welcome URL (query params)
tenantId="$(python3 - <<PY 2>/dev/null || true
import sys, urllib.parse
u = urllib.parse.urlparse("$welcome")
q = urllib.parse.parse_qs(u.query)
print(q.get("tenantId", [""])[0])
PY
)"
k="$(python3 - <<PY 2>/dev/null || true
import sys, urllib.parse
u = urllib.parse.urlparse("$welcome")
q = urllib.parse.parse_qs(u.query)
print(q.get("k", [""])[0])
PY
)"

if [ -z "${tenantId:-}" ] || [ -z "${k:-}" ]; then
  echo "WARN: could not extract tenantId+k from welcome URL (still OK)."
  echo "      Copy them from the Welcome page if needed."
else
  echo "OK: tenantId extracted"
  echo "OK: k extracted (hidden)"
fi
echo

# 6) Send leads to webhook (intake)
echo "==> 5) Send demo leads to /api/webhook/intake"
if [ ! -f "$LEADS_FILE" ]; then
  echo "FAIL: leads file missing: $LEADS_FILE" >&2
  exit 7
fi

sent=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/api/webhook/intake" \
    -H "content-type: application/json" \
    --data "$line" || true)"
  echo "lead[$sent] => HTTP $code"
  sent=$((sent+1))
done < "$LEADS_FILE"

echo "OK: leads sent = $sent"
echo

# 7) Open Tickets + Exports (if we have tenantId+k)
if [ -n "${tenantId:-}" ] && [ -n "${k:-}" ]; then
  tickets="$BASE_URL/ui/tickets?tenantId=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)&k=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"
  csv="$BASE_URL/ui/export.csv?tenantId=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)&k=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"
  zip="$BASE_URL/ui/evidence.zip?tenantId=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)&k=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"

  echo "==> 6) Open Tickets + Exports"
  echo "Tickets: $tickets"
  echo "CSV:     $csv"
  echo "ZIP:     $zip"
  echo

  if command -v open >/dev/null 2>&1; then
    open "$tickets" || true
    open "$csv" || true
    open "$zip" || true
  fi
else
  echo "==> 6) Skipped auto-open tickets/exports because tenantId+k not extracted."
  echo "Open Welcome and copy the links from there."
fi

echo
echo "✅ DONE — You now experienced the pilot like a real agency user."
echo "Next: replace demo leads with real Zapier leads and sell the paid pilot."
