#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
if [ ! -f "$ROOT/package.json" ]; then
  echo "FAIL: run inside repo root (package.json missing)" >&2
  exit 1
fi

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"
echo "==> One-shot: EADDRINUSE fix + Client A2Z experience"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

# -----------------------------
# 1) port free helper
# -----------------------------
cat > scripts/port_free_7090.sh <<'PORT'
#!/usr/bin/env bash
set -euo pipefail
PORT="${1:-7090}"

echo "==> Checking port :$PORT"
pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"

if [ -z "${pids:-}" ]; then
  echo "OK: port $PORT is free"
  exit 0
fi

echo "WARN: port $PORT is in use by PID(s): $pids"
echo "==> Killing listeners on :$PORT"
# try graceful first
for pid in $pids; do
  kill "$pid" 2>/dev/null || true
done

sleep 0.5

# force if still alive
pids2="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "${pids2:-}" ]; then
  echo "==> Force kill"
  for pid in $pids2; do
    kill -9 "$pid" 2>/dev/null || true
  done
fi

sleep 0.2
pids3="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
if [ -n "${pids3:-}" ]; then
  echo "FAIL: could not free port $PORT. Remaining: $pids3" >&2
  exit 2
fi

echo "OK: port $PORT freed"
PORT
chmod +x scripts/port_free_7090.sh

# -----------------------------
# 2) dev runner on 7090
# -----------------------------
cat > scripts/dev_7090.sh <<'DEV'
#!/usr/bin/env bash
set -euo pipefail
PORT="${PORT:-7090}"

# free port first
bash ./scripts/port_free_7090.sh "$PORT"

echo "==> Starting dev server on :$PORT"
# server.ts reads PORT env; ensure it is set
export PORT="$PORT"

pnpm dev
DEV
chmod +x scripts/dev_7090.sh

# -----------------------------
# 3) Client experience A2Z (uses existing auth flow + welcome + demo leads + opens links)
# -----------------------------
cat > scripts/client_experience_a2z.sh <<'A2Z'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
EMAIL="${EMAIL:-test+agency@local.dev}"
DATA_DIR="${DATA_DIR:-./data}"
LEADS_FILE="${LEADS_FILE:-./scripts/demo_leads.jsonl}"

echo "==> Client Experience A2Z"
echo "==> BASE_URL  = $BASE_URL"
echo "==> EMAIL     = $EMAIL"
echo "==> DATA_DIR  = $DATA_DIR"
echo "==> LEADS     = $LEADS_FILE"
echo

# 0) health
code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: server not healthy on $BASE_URL (got HTTP $code)." >&2
  echo "TIP: run: bash scripts/dev_7090.sh" >&2
  exit 1
fi
echo "OK: /health => 200"
echo

# 1) request login link (writes outbox in dev)
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

# 2) read latest outbox + extract verify URL
echo
echo "==> 2) Read latest outbox email + extract verify URL"
mail="$(ls -1t "$DATA_DIR/outbox"/mail_*.txt 2>/dev/null | head -n 1 || true)"
if [ -z "${mail:-}" ]; then
  echo "FAIL: no outbox mail found in $DATA_DIR/outbox" >&2
  exit 3
fi
echo "OK: latest mail => $mail"

verify_url="$(cat "$mail" | rg -o 'https?://[^ ]+' | head -n 1 || true)"
if [ -z "${verify_url:-}" ]; then
  echo "FAIL: could not find verify URL in outbox mail." >&2
  echo "TIP: open the mail and copy manually: open \"$mail\"" >&2
  exit 4
fi
echo "OK: verify URL extracted (hidden)"
echo

# 3) hit verify URL -> expect redirect to /ui/welcome?tenantId=...&k=...
echo "==> 3) Verify (expect redirect to /ui/welcome)"
loc="$(curl -sS -o /dev/null -D - "$verify_url" | rg -i '^location:' | head -n 1 | sed -E 's/location:\s*//I' | tr -d '\r' || true)"
if [ -z "${loc:-}" ]; then
  echo "FAIL: expected Location header from verify endpoint." >&2
  exit 5
fi
echo "OK: redirect => $loc"

if [[ "$loc" =~ ^/ ]]; then
  welcome="$BASE_URL$loc"
else
  welcome="$loc"
fi
echo "OK: welcome => $welcome"
echo

# 4) open welcome
if command -v open >/dev/null 2>&1; then
  echo "==> 4) Opening Welcome UI"
  open "$welcome" || true
else
  echo "==> 4) Open this:"
  echo "$welcome"
fi

# 5) extract tenantId+k
tenantId="$(python3 - <<PY 2>/dev/null || true
import urllib.parse
u = urllib.parse.urlparse("$welcome")
q = urllib.parse.parse_qs(u.query)
print(q.get("tenantId", [""])[0])
PY
)"
k="$(python3 - <<PY 2>/dev/null || true
import urllib.parse
u = urllib.parse.urlparse("$welcome")
q = urllib.parse.parse_qs(u.query)
print(q.get("k", [""])[0])
PY
)"

if [ -z "${tenantId:-}" ] || [ -z "${k:-}" ]; then
  echo "WARN: tenantId/k not found in welcome URL query."
  echo "      You can still use the links shown on the Welcome page."
else
  echo "OK: tenantId extracted"
  echo "OK: k extracted (hidden)"
fi
echo

# 6) send leads
echo "==> 5) Send demo leads to webhook"
if [ ! -f "$LEADS_FILE" ]; then
  echo "FAIL: leads file missing: $LEADS_FILE" >&2
  exit 6
fi

i=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/api/webhook/intake" \
    -H "content-type: application/json" \
    --data "$line" || true)"
  echo "lead[$i] => HTTP $code"
  i=$((i+1))
done < "$LEADS_FILE"
echo "OK: leads sent = $i"
echo

# 7) open tickets/csv/zip
if [ -n "${tenantId:-}" ] && [ -n "${k:-}" ]; then
  enc_tenant="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$tenantId"))
PY
)"
  enc_k="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$k"))
PY
)"
  tickets="$BASE_URL/ui/tickets?tenantId=$enc_tenant&k=$enc_k"
  csv="$BASE_URL/ui/export.csv?tenantId=$enc_tenant&k=$enc_k"
  zip="$BASE_URL/ui/evidence.zip?tenantId=$enc_tenant&k=$enc_k"

  echo "==> 6) Opening Tickets + CSV + ZIP"
  echo "Tickets: $tickets"
  echo "CSV:     $csv"
  echo "ZIP:     $zip"

  if command -v open >/dev/null 2>&1; then
    open "$tickets" || true
    open "$csv" || true
    open "$zip" || true
  fi
else
  echo "==> 6) Skipped auto-open tickets/exports (no tenantId/k)."
  echo "Open Welcome and click the links."
fi

echo
echo "✅ DONE — This is the full client pilot experience."
A2Z
chmod +x scripts/client_experience_a2z.sh

# -----------------------------
# 4) ensure demo leads exist (only create if missing)
# -----------------------------
if [ ! -f scripts/demo_leads.jsonl ]; then
cat > scripts/demo_leads.jsonl <<'JSONL'
{"source":"zapier","type":"lead","lead":{"fullName":"Jane Doe","email":"jane@example.com","company":"Acme","utm":"gads_search"}}
{"source":"zapier","type":"lead","lead":{"fullName":"Omar Benali","email":"omar@studio.co","company":"StudioCo","utm":"meta_ads"}}
{"source":"zapier","type":"lead","lead":{"fullName":"Sarah Martin","email":"sarah@agency.fr","company":"AgencyFR","utm":"linkedin"}}
{"source":"zapier","type":"lead","lead":{"fullName":"Jane Doe","email":"jane@example.com","company":"Acme","utm":"gads_search"}}
{"source":"zapier","type":"lead","lead":{"fullName":"Ilyes K.","email":"ilyes@ecom.io","company":"EcomIO","utm":"tiktok"}}
JSONL
fi

echo "OK ✅ Added scripts:"
echo " - scripts/port_free_7090.sh"
echo " - scripts/dev_7090.sh"
echo " - scripts/client_experience_a2z.sh"
echo
echo "NEXT:"
echo "  1) Start server (this frees port automatically):"
echo "     bash scripts/dev_7090.sh"
echo
echo "  2) In another terminal, run client experience:"
echo "     bash scripts/client_experience_a2z.sh"
echo
echo "Backups: $BAK"
