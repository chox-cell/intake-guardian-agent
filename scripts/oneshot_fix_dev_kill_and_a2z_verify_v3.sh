#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK/scripts"

cp -v scripts/dev-kill-7090-and-start.sh "$BAK/scripts/dev-kill-7090-and-start.sh.bak" 2>/dev/null || true
cp -v scripts/client_experience_a2z.sh "$BAK/scripts/client_experience_a2z.sh.bak" 2>/dev/null || true

# 1) Make dev-kill script ASCII-only and NEVER patch code again
cat > scripts/dev-kill-7090-and-start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# ASCII-only runner. No patching, no perl.
# Use the canonical dev script that frees the port then runs pnpm dev.
exec bash scripts/dev_7090.sh
EOF
chmod +x scripts/dev-kill-7090-and-start.sh

# 2) Patch client experience A2Z (robust verify)
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

# Extract clean absolute URL(s), then pick the first one containing /api/auth/verify
VERIFY_URL="$(grep -Eo 'https?://[^[:space:]"'"'"']+' "$MAIL" | grep '/api/auth/verify' | head -n 1 || true)"

# Fallback: relative verify link
if [ -z "${VERIFY_URL:-}" ]; then
  REL="$(grep -Eo '/api/auth/verify\?[^[:space:]"'"'"']+' "$MAIL" | head -n 1 || true)"
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

echo "==> 3) Verify (follow redirects; capture final URL)"
# Follow redirects and capture the final effective URL (this avoids relying on Location header)
FINAL_URL="$(curl -sS -L -o /dev/null -w "%{url_effective}" "$VERIFY_URL" || true)"

if [ -z "${FINAL_URL:-}" ]; then
  echo "FAIL: could not resolve final URL from verify" >&2
  exit 1
fi

# Some servers end on /ui/welcome?tenantId=...&k=...
if [[ "$FINAL_URL" != *"/ui/welcome"* ]]; then
  # Try one more: request headers/body to find a welcome link
  HDR="/tmp/a2z_hdr.$$"
  BODY="/tmp/a2z_body.$$"
  rm -f "$HDR" "$BODY"
  curl -sS -D "$HDR" -o "$BODY" "$VERIFY_URL" || true

  LOC="$(awk 'tolower($1)=="location:"{print $2}' "$HDR" 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
  if [ -n "${LOC:-}" ]; then
    if [[ "$LOC" == /* ]]; then
      FINAL_URL="$BASE_URL$LOC"
    else
      FINAL_URL="$LOC"
    fi
  else
    WREL="$(grep -Eo '/ui/welcome\?tenantId=[^[:space:]"'"'"']+' "$BODY" | head -n 1 || true)"
    if [ -n "${WREL:-}" ]; then
      FINAL_URL="$BASE_URL$WREL"
    fi
  fi
  rm -f "$HDR" "$BODY" || true
fi

if [[ "$FINAL_URL" != *"/ui/welcome"* ]]; then
  echo "FAIL: verify did not lead to /ui/welcome (final=$FINAL_URL)" >&2
  exit 1
fi

WELCOME="$FINAL_URL"
echo "OK: welcome => $WELCOME"
echo

# Extract tenantId + k
TENANT_ID="$(python - <<PY
import urllib.parse as u, sys
p=u.urlparse(sys.argv[1])
q=u.parse_qs(p.query)
print((q.get("tenantId") or [""])[0])
PY
"$WELCOME")"

K="$(python - <<PY
import urllib.parse as u, sys
p=u.urlparse(sys.argv[1])
q=u.parse_qs(p.query)
print((q.get("k") or [""])[0])
PY
"$WELCOME")"

if [ -z "${TENANT_ID:-}" ] || [ -z "${K:-}" ]; then
  echo "FAIL: welcome URL missing tenantId/k" >&2
  echo "welcome=$WELCOME" >&2
  exit 1
fi

echo "OK: tenantId extracted"
echo "OK: k extracted (hidden)"
echo

echo "==> 4) Open Welcome UI"
if command -v open >/dev/null 2>&1; then
  open "$WELCOME" || true
fi
echo

echo "==> 5) Send demo leads to webhook (with tenant auth)"
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

echo "==> 6) Open Pages"
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

echo "✅ DONE — Full client pilot experience completed."
EOF

chmod +x scripts/client_experience_a2z.sh

echo "OK ✅ Applied:"
echo " - scripts/dev-kill-7090-and-start.sh (now just runs dev_7090.sh, no patching, no unicode)"
echo " - scripts/client_experience_a2z.sh (robust verify via curl -L url_effective + clean URL extraction)"
echo "Backup: $BAK"
