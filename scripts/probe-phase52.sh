#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

# Phase59d: autoload .env.local for this script (no secrets printed)
source "$ROOT/scripts/_envlocal.sh"


DATA_DIR="${DATA_DIR:-./data}"

# If user didn't set TENANT_ID, try to infer from TENANT_KEYS_JSON (single-key object)
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

echo "==> Phase52 Probe (tenant key source, NO secrets)"
echo "==> ROOT      = $ROOT"
echo "==> DATA_DIR  = $DATA_DIR"
echo "==> TENANT_ID = $TENANT_ID"
echo

echo "==> Env presence (not values)"
echo "TENANT_KEY_DEMO present?  $([ -n "${TENANT_KEY_DEMO:-}" ] && echo YES || echo NO)"
echo "TENANT_KEYS present?      $([ -n "${TENANT_KEYS:-}" ] && echo YES || echo NO)"
echo "TENANT_KEYS_JSON present? $([ -n "${TENANT_KEYS_JSON:-}" ] && echo YES || echo NO)"
echo "ADMIN_KEY present?        $([ -n "${ADMIN_KEY:-}" ] && echo YES || echo NO)"
echo

detect_key(){
  # 1) explicit (legacy)
  if [ -n "${TENANT_KEY_DEMO:-}" ]; then printf "%s" "$TENANT_KEY_DEMO"; return; fi

  # 2) TENANT_KEYS (json or pairs)
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

  # 3) TENANT_KEYS_JSON (preferred): simple mapping { "tenantId": "key" }
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

  # 4) data resolver (best-effort) if helper exists
  if [ -f scripts/_detect_demo_key_from_data.node.cjs ]; then
    DATA_DIR="$DATA_DIR" TENANT_ID="$TENANT_ID" node scripts/_detect_demo_key_from_data.node.cjs 2>/dev/null || true
  fi
}

KEY="$(detect_key||true)"
if [ -z "$KEY" ]; then
  echo "RESULT: NOT_FOUND"
  echo "Fix one of:"
  echo "  - export TENANT_KEY_DEMO=..."
  echo "  - export TENANT_KEYS='{\"$TENANT_ID\":\"...\"}' or '$TENANT_ID:...'"
  echo "  - export TENANT_KEYS_JSON='{\"$TENANT_ID\":\"...\"}'  (recommended)"
  exit 2
fi

LEN="$(printf "%s" "$KEY" | wc -c | tr -d ' ')"
echo "RESULT: FOUND"
if [ -n "${TENANT_KEY_DEMO:-}" ]; then
  echo "SOURCE: env:TENANT_KEY_DEMO"
elif [ -n "${TENANT_KEYS_JSON:-}" ]; then
  echo "SOURCE: env:TENANT_KEYS_JSON"
elif [ -n "${TENANT_KEYS:-}" ]; then
  echo "SOURCE: env:TENANT_KEYS"
else
  echo "SOURCE: data (best-effort)"
fi
echo "LENGTH: $LEN"
echo "✅ Probe complete"
