#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $1"; exit 1; }

echo "==> [0] health"
curl -sS "$BASE_URL/health" >/dev/null || fail "health not ok"
echo "✅ health ok"

[ -n "$ADMIN_KEY" ] || fail "missing ADMIN_KEY"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -D- "$BASE_URL/ui" | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui not hidden"

echo "==> [2] /ui/admin redirect (302) + capture Location"
hdr="$(curl -sS -o /dev/null -D- "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
loc="$(echo "$hdr" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | tail -n 1)"
[ -n "$loc" ] || { echo "$hdr" | sed -n '1,25p'; fail "no Location from /ui/admin"; }
echo "Location=$loc"

TENANT_ID="$(echo "$loc" | sed -n 's/.*[?&]tenantId=\([^&]*\).*/\1/p')"
TENANT_KEY="$(echo "$loc" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"

echo "TENANT_ID=$TENANT_ID"
echo "TENANT_KEY=$TENANT_KEY"
[ -n "$TENANT_ID" ] || fail "could not parse tenantId from Location"
[ -n "$TENANT_KEY" ] || fail "could not parse k from Location"

echo "==> [3] webhook intake #1 should be 201 (created true/false ok)"
payload='{"source":"zapier","type":"lead","lead":{"fullName":"Jane Doe","email":"jane@example.com","phone":"+33 6 00 00 00 00","raw":{"demo":"no","ts":"'$(date -u +%FT%TZ)'"}}}'
r1="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" -H "Content-Type: application/json" -d "$payload")"
b1="$(echo "$r1" | head -n 1)"
c1="$(echo "$r1" | tail -n 1)"
echo "status=$c1"
echo "$b1"
[ "$c1" = "201" ] || fail "webhook #1 not 201"

id="$(echo "$b1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.ticket?.id||"")}catch{console.log("")}})')"
[ -n "$id" ] || fail "missing ticket.id in webhook response"

echo "==> [4] webhook intake #2 same payload should NOT create new ticket (created=false expected) + duplicateCount>=1"
r2="$(curl -sS -w "\n%{http_code}\n" -X POST "$BASE_URL/api/webhook/intake?tenantId=$TENANT_ID&k=$TENANT_KEY" -H "Content-Type: application/json" -d "$payload")"
b2="$(echo "$r2" | head -n 1)"
c2="$(echo "$r2" | tail -n 1)"
echo "status=$c2"
echo "$b2"
[ "$c2" = "201" ] || fail "webhook #2 not 201"

created2="$(echo "$b2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(String(j.created))}catch{console.log("")}})')"
dup2="$(echo "$b2" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);console.log(j.ticket?.duplicateCount??"")}catch{console.log("")}})')"
[ "$created2" = "false" ] || fail "expected created=false on duplicate"
[ -n "$dup2" ] || fail "missing duplicateCount"
echo "duplicateCount=$dup2"

echo
echo "✅ Phase33 smoke OK"
echo "Setup:"
echo "  $BASE_URL/ui/setup?tenantId=$TENANT_ID&k=$TENANT_KEY"
