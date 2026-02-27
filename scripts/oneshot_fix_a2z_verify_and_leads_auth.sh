#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK/scripts"

cp -v scripts/client_experience_a2z.sh "$BAK/scripts/client_experience_a2z.sh.bak" 2>/dev/null || true

cat > scripts/client_experience_a2z.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# auto-load .env.local (no secrets printed)
if [ -f "./.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env.local" || true
  set +a
fi

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

code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: /health expected 200, got $code" >&2
  exit 1
fi
echo "OK: /health => 200"
echo

echo "==> 1) Request login link"
code="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/api/auth/request-link" \
  -H "content-type: application/json" \
  --data "{\"email\":\"$EMAIL\"}" || true)"
echo "request-link => HTTP $code"
if [ "$code" != "200" ]; then
  echo "FAIL: request-link expected 200" >&2
  exit 1
fi
echo

echo "==> 2) Read latest outbox email + extract verify URL"
OUTBOX_DIR="$DATA_DIR/outbox"
if [ ! -d "$OUTBOX_DIR" ]; then
  echo "FAIL: outbox dir not found: $OUTBOX_DIR" >&2
  exit 1
fi

MAIL="$(ls -1t "$OUTBOX_DIR"/mail_*.txt 2>/dev/null | head -n 1 || true)"
if [ -z "${MAIL:-}" ]; then
  echo "FAIL: no outbox mail found in $OUTBOX_DIR" >&2
  exit 1
fi
echo "OK: latest mail => $MAIL"

VERIFY_URL="$(grep -Eo 'https?://[^[:space:]]+' "$MAIL" | rg -n '\/api\/auth\/verify' -o -m 1 || true)"
if [ -z "${VERIFY_URL:-}" ]; then
  # fallback: sometimes URL is relative
  REL="$(rg -n '\/api\/auth\/verify\?[^"'\''[:space:]]+' -o -m 1 "$MAIL" || true)"
  if [ -n "${REL:-}" ]; then
    VERIFY_URL="$BASE_URL$REL"
  fi
fi

if [ -z "${VERIFY_URL:-}" ]; then
  echo "FAIL: could not extract verify URL from outbox mail" >&2
  exit 1
fi
echo "OK: verify URL extracted (hidden)"
echo

echo "==> 3) Verify (expect redirect or body with welcome link)"
HDR="/tmp/a2z_hdr.$$"
BODY="/tmp/a2z_body.$$"
rm -f "$HDR" "$BODY"

# Don't follow redirects here; we want Location if present
curl -sS -D "$HDR" -o "$BODY" "$VERIFY_URL" || true

STATUS="$(awk 'NR==1{print $2}' "$HDR" 2>/dev/null || true)"
LOC="$(awk 'tolower($1)=="location:"{print $2}' "$HDR" 2>/dev/null | tr -d '\r' | tail -n 1 || true)"

WELCOME=""
if [ -n "${LOC:-}" ]; then
  # If relative, prefix base
  if [[ "$LOC" == /* ]]; then
    WELCOME="$BASE_URL$LOC"
  else
    WELCOME="$LOC"
  fi
else
  # Some implementations return 200 + HTML containing /ui/welcome?... or full URL
  WELCOME_REL="$(rg -n '\/ui\/welcome\?tenantId=[^"'\''[:space:]]+' -o -m 1 "$BODY" || true)"
  if [ -n "${WELCOME_REL:-}" ]; then
    WELCOME="$BASE_URL$WELCOME_REL"
  else
    WELCOME_ABS="$(rg -n 'https?:\/\/[^"'\''[:space:]]+\/ui\/welcome\?tenantId=[^"'\''[:space:]]+' -o -m 1 "$BODY" || true)"
    if [ -n "${WELCOME_ABS:-}" ]; then
      WELCOME="$WELCOME_ABS"
    fi
  fi
fi

rm -f "$HDR" "$BODY" || true

if [ -z "${WELCOME:-}" ]; then
  echo "FAIL: no redirect location from verify (status=${STATUS:-unknown})" >&2
  echo "Hint: verify endpoint returned no Location and no welcome URL in body." >&2
  exit 1
fi

echo "OK: welcome => $WELCOME"
echo

# Extract tenantId + k from welcome URL
TENANT_ID="$(python - <<PY
import urllib.parse as u, sys
url = sys.argv[1]
q = u.urlparse(url).query
p = u.parse_qs(q)
print((p.get("tenantId") or [""])[0])
PY
"$WELCOME")"

K="$(python - <<PY
import urllib.parse as u, sys
url = sys.argv[1]
q = u.urlparse(url).query
p = u.parse_qs(q)
print((p.get("k") or [""])[0])
PY
"$WELCOME")"

if [ -z "${TENANT_ID:-}" ] || [ -z "${K:-}" ]; then
  echo "FAIL: could not extract tenantId/k from welcome URL" >&2
  exit 1
fi
echo "OK: tenantId extracted"
echo "OK: k extracted (hidden)"
echo

echo "==> 4) Opening Welcome UI"
if command -v open >/dev/null 2>&1; then
  open "$WELCOME" || true
fi
echo

echo "==> 5) Send demo leads to webhook (WITH tenant auth)"
if [ ! -f "$LEADS" ]; then
  echo "FAIL: leads file not found: $LEADS" >&2
  exit 1
fi

i=0
while IFS= read -r line; do
  [ -z "${line:-}" ] && continue
  code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/api/webhook/intake?tenantId=$(python -c "import urllib.parse as u; print(u.quote('''$TENANT_ID'''))")&k=$(python -c "import urllib.parse as u; print(u.quote('''$K'''))")" \
    -H "content-type: application/json" \
    --data "$line" || true)"
  echo "lead[$i] => HTTP $code"
  i=$((i+1))
done < "$LEADS"
echo "OK: leads sent = $i"
echo

echo "==> 6) Opening Tickets + CSV + ZIP + Pilot Pack"
TICKETS="$BASE_URL/ui/tickets?tenantId=$TENANT_ID&k=$K"
CSV="$BASE_URL/ui/export.csv?tenantId=$TENANT_ID&k=$K"
ZIP="$BASE_URL/ui/evidence.zip?tenantId=$TENANT_ID&k=$K"
PILOT="$BASE_URL/ui/pilot?tenantId=$TENANT_ID&k=$K"
SETUP="$BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$K"
DECISIONS="$BASE_URL/ui/decisions?tenantId=$TENANT_ID&k=$K"

echo "Decisions: $DECISIONS"
echo "Tickets:   $TICKETS"
echo "Setup:     $SETUP"
echo "CSV:       $CSV"
echo "ZIP:       $ZIP"
echo "Pilot:     $PILOT"
echo

if command -v open >/dev/null 2>&1; then
  open "$DECISIONS" || true
  open "$TICKETS" || true
  open "$SETUP" || true
  open "$CSV" || true
  open "$ZIP" || true
  open "$PILOT" || true
fi

echo "✅ DONE — This is the full client pilot experience."
EOF

chmod +x scripts/client_experience_a2z.sh

echo "OK: patched scripts/client_experience_a2z.sh (robust verify + webhook auth + better open)."
echo "Backup: $BAK"
