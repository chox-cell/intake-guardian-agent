#!/usr/bin/env bash
set -euo pipefail

# auto-load .env.local for local runs (no secrets printed)
if [ -f "./.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env.local" || true
  set +a
fi

if [ -z "${TENANT_ID:-}" ]; then
  echo "FAIL: TENANT_ID is empty. Either export TENANT_ID or ensure .env.local has TENANT_ID." >&2
  exit 2
fi


BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
DATA_DIR="${DATA_DIR:-./data}"

TENANT_ID="${TENANT_ID:-}"
KEY="${TENANT_KEY:-}"

if [ -z "${TENANT_ID}" ]; then
  if [ -n "${TENANT_ID_ENV:-}" ]; then TENANT_ID="${TENANT_ID_ENV}"; fi
fi

if [ -z "${TENANT_ID}" ] && [ -f "${DATA_DIR}/tenant.json" ]; then
  TENANT_ID="$(node -e 'const fs=require("fs");try{const j=JSON.parse(fs.readFileSync(process.env.DATA_DIR+"/tenant.json","utf8"));process.stdout.write(String(j.tenantId||""))}catch{}' )"
fi

if [ -z "${KEY}" ] && [ -n "${TENANT_ID}" ] && [ -n "${TENANT_KEYS_JSON:-}" ]; then
  KEY="$(node -e 'const id=process.env.TENANT_ID; const j=JSON.parse(process.env.TENANT_KEYS_JSON||"{}"); process.stdout.write(String(j[id]||""))' TENANT_ID="${TENANT_ID}")"
fi

echo "==> SMOKE Tenant Auth (webhook)"
echo "==> BASE_URL  = ${BASE_URL}"
echo "==> TENANT_ID = ${TENANT_ID}"
echo "==> DATA_DIR  = ${DATA_DIR}"
echo "==> KEY_LEN   = ${#KEY}"
echo

req() {
  local label="$1"; shift
  local method="$1"; shift
  local url="$1"; shift

  local tmp
  tmp="$(mktemp)"
  local code
  code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" "$@" || true)"

  local err=""
  err="$(node - <<'NODE' "$tmp"
const fs=require("fs");
const p=process.argv[2];
try{
  const j=JSON.parse(fs.readFileSync(p,"utf8"));
  if(j && typeof j.error==="string") process.stdout.write(j.error);
}catch{}
NODE
)"

  echo "$label => HTTP $code${err:+ (error=$err)}" >&2
  printf "%s" "$code"
}

echo "==> 0) health"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: /health expected 200, got $code"
  exit 1
fi
echo "OK: /health => 200"
echo

echo "==> 1) missing tenantId (should 400 missing_tenant_id)"
c="$(req "A" "POST" "$BASE_URL/api/webhook/intake" \
  -H "content-type: application/json" \
  --data '{"source":"smoke","type":"test","lead":{"name":"x"}}')"
if [ "$c" != "400" ]; then echo "FAIL: expected 400"; exit 1; fi
echo

echo "==> 2) missing tenant key (should 401 missing_tenant_key)"
c="$(req "B" "POST" "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID" \
  -H "content-type: application/json" \
  --data '{"source":"smoke","type":"test","lead":{"name":"x"}}')"
if [ "$c" != "401" ]; then echo "FAIL: expected 401"; exit 1; fi
echo

echo "==> 3) invalid key (should 401 invalid_tenant_key)"
BAD="bad_bad_bad_bad_bad_bad_bad_bad"
c="$(req "C" "POST" "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$BAD" \
  -H "content-type: application/json" \
  --data '{"source":"smoke","type":"test","lead":{"name":"x"}}')"
if [ "$c" != "401" ]; then echo "FAIL: expected 401"; exit 1; fi
echo

echo "==> 4) valid key via query k (should 201)"
c="$(req "D" "POST" "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$KEY" \
  -H "content-type: application/json" \
  --data '{"source":"smoke","type":"test","lead":{"name":"ok-query"}}')"
if [ "$c" != "201" ]; then echo "FAIL: expected 201"; exit 1; fi
echo

echo "==> 5) valid key via header x-tenant-key (should 201)"
c="$(req "E" "POST" "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID" \
  -H "x-tenant-key: $KEY" \
  -H "content-type: application/json" \
  --data '{"source":"smoke","type":"test","lead":{"name":"ok-header"}}')"
if [ "$c" != "201" ]; then echo "FAIL: expected 201"; exit 1; fi
echo

echo "==> 6) both header + query (should 201)"
c="$(req "F" "POST" "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$KEY" \
  -H "x-tenant-key: $KEY" \
  -H "content-type: application/json" \
  --data '{"source":"smoke","type":"test","lead":{"name":"ok-both"}}')"
if [ "$c" != "201" ]; then echo "FAIL: expected 201"; exit 1; fi
echo

echo "==> 7) wrong header name should NOT authenticate (expect 401 missing_tenant_key)"
c="$(req "G" "POST" "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID" \
  -H "x-api-key: $KEY" \
  -H "content-type: application/json" \
  --data '{"source":"smoke","type":"test","lead":{"name":"bad-header"}}')"
if [ "$c" != "401" ]; then echo "FAIL: expected 401"; exit 1; fi

echo
echo "✅ SMOKE OK (tenant auth + webhook contract)"
