#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

# Phase59d: autoload .env.local for this script (no secrets printed)
source "$ROOT/scripts/_envlocal.sh"


BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
DATA_DIR="${DATA_DIR:-./data}"

# Infer tenant id from TENANT_KEYS_JSON if not provided and it has exactly one key
if [ -z "${TENANT_ID:-}" ] && [ -n "${TENANT_KEYS_JSON:-}" ]; then
  TENANT_ID="$(node - <<'NODE' 2>/dev/null || true
try {
  const j = JSON.parse(process.env.TENANT_KEYS_JSON || "{}");
  const ks = (j && typeof j === "object" && !Array.isArray(j)) ? Object.keys(j) : [];
  if (ks.length === 1) process.stdout.write(ks[0]);
} catch {}
NODE
)"
fi
TENANT_ID="${TENANT_ID:-demo}"

detect_key(){
  # 1) legacy explicit
  if [ -n "${TENANT_KEY_DEMO:-}" ]; then printf "%s" "$TENANT_KEY_DEMO"; return; fi

  # 2) preferred: TENANT_KEYS_JSON
  if [ -n "${TENANT_KEYS_JSON:-}" ]; then
    node - "$TENANT_ID" <<'NODE' 2>/dev/null || true
const tid=process.argv[2]||"demo";
try{
  const j=JSON.parse(process.env.TENANT_KEYS_JSON||"{}");
  const v=j?.[tid];
  if(typeof v==="string")process.stdout.write(v);
  else if(v&&typeof v==="object"){
    for(const k of["key","apiKey","token","secret","tenantKey"]){
      if(typeof v[k]==="string"){process.stdout.write(v[k]);break;}
    }
  }
}catch{}
NODE
    return
  fi

  # 3) TENANT_KEYS (json or pairs)
  if [ -n "${TENANT_KEYS:-}" ]; then
    if printf "%s" "$TENANT_KEYS" | head -c 1 | grep -q '{'; then
      node - "$TENANT_ID" <<'NODE' 2>/dev/null || true
const tid=process.argv[2]||"demo";
try{
  const j=JSON.parse(process.env.TENANT_KEYS||"{}");
  const v=j?.[tid];
  if(typeof v==="string")process.stdout.write(v);
  else if(v&&typeof v==="object"){
    for(const k of["key","apiKey","token","secret","tenantKey"]){
      if(typeof v[k]==="string"){process.stdout.write(v[k]);break;}
    }
  }
}catch{}
NODE
      return
    fi
    pair="$(printf "%s" "$TENANT_KEYS"|tr ',;' '  '|tr ' ' '\n'|grep -E "^${TENANT_ID}[:=]"|head -n1||true)"
    [ -n "$pair" ] && printf "%s" "$pair"|sed -E "s/^${TENANT_ID}[:=]//" && return
  fi

  # 4) data helper if exists
  if [ -f scripts/_detect_demo_key_from_data.node.cjs ]; then
    DATA_DIR="$DATA_DIR" TENANT_ID="$TENANT_ID" node scripts/_detect_demo_key_from_data.node.cjs 2>/dev/null || true
  fi
}

echo "==> Phase48 E2E (strict, TENANT_KEYS_JSON-aware)"
echo "==> BASE_URL   = $BASE_URL"
echo "==> TENANT_ID  = $TENANT_ID"
echo "==> DATA_DIR   = $DATA_DIR"

KEY="$(detect_key||true)"
if [ -z "$KEY" ]; then
  echo "FAIL: could not detect tenant key for TENANT_ID=$TENANT_ID"
  echo "Fix one of:"
  echo "  - export TENANT_KEYS_JSON='{\"$TENANT_ID\":\"...\"}'   (recommended)"
  echo "  - export TENANT_KEY_DEMO=..."
  exit 2
fi

LEN="$(printf "%s" "$KEY"|wc -c|tr -d ' ')"
ENC="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]||""))' "$KEY")"
echo "==> TENANT_KEY = (detected, length=$LEN)"

PORT="$(printf "%s" "$BASE_URL"|sed -E 's#^https?://[^:]+:([0-9]+).*#\1#')"
if [ -n "$PORT" ] && command -v lsof >/dev/null 2>&1; then
  kill -9 $(lsof -ti tcp:"$PORT" 2>/dev/null) >/dev/null 2>&1 || true
fi

pnpm dev >/tmp/intake-guardian-e2e.log 2>&1 & PID=$!

for i in $(seq 1 80); do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
    echo "OK: health ready"
    break
  fi
  sleep .2
done

RESP="/tmp/intake-guardian-e2e.res"
HTTP="$(curl -sS -o "$RESP" -w "%{http_code}" \
  -H "content-type: application/json" \
  -H "x-tenant-key: $KEY" \
  -X POST \
  --data '{"source":"zapier","type":"lead","channel":"meta","presetId":"paid_ads.v1","lead":{"fullName":"Meta Lead","email":"lead@client.com","company":"Client Co"},"tracking":{"hasPixel":true,"hasConversionApi":false,"hasGtm":true,"hasUtm":false,"hasThankYouPage":true},"offer":{"hasClearOffer":true},"assets":{"hasLandingPage":true,"hasCreativeAssets":true},"notes":"Meta lead intake"}' \
  "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$ENC")"

echo "==> HTTP $HTTP"
if [ "$HTTP" != "200" ] && [ "$HTTP" != "201" ]; then
  cat "$RESP" || true
  echo "---- server log tail ----"
  tail -n 40 /tmp/intake-guardian-e2e.log || true
  kill -9 "$PID" >/dev/null 2>&1 || true
  exit 1
fi

node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(j.ok!==true||!j.ticket||!j.ticket.id||j.ticket.status!=="ready"){process.exit(2)}' "$RESP"
kill -9 "$PID" >/dev/null 2>&1 || true
echo "✅ Phase48 E2E OK"
