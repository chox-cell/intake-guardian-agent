#!/usr/bin/env bash
set -euo pipefail

# auto-load .env.local for local runs (no secrets printed)
if [ -f "./.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "./.env.local" || true
  set +a
fi

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
EMAIL="${EMAIL:-test+agency@local.dev}"
DATA_DIR="${DATA_DIR:-./data}"

echo "==> SMOKE Auth Provisioning (request-link -> outbox -> verify -> welcome)"
echo "==> BASE_URL = $BASE_URL"
echo "==> EMAIL    = $EMAIL"
echo

code="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
if [ "$code" != "200" ]; then
  echo "FAIL: /health expected 200, got $code" >&2
  exit 1
fi
echo "OK: /health"

# Request link (should 200)
code="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/api/auth/request-link" \
  -H "content-type: application/json" \
  --data "{\"email\":\"$EMAIL\"}" || true)"

echo "request-link => HTTP $code"
if [ "$code" != "200" ]; then
  echo "FAIL: expected 200" >&2
  exit 1
fi

# Find newest outbox mail and extract verify URL
OUTDIR="$DATA_DIR/outbox"
if [ ! -d "$OUTDIR" ]; then
  echo "FAIL: outbox dir missing: $OUTDIR" >&2
  exit 1
fi

latest="$(ls -1t "$OUTDIR"/mail_*.txt 2>/dev/null | head -n 1 || true)"
if [ -z "$latest" ]; then
  echo "FAIL: no outbox mail_*.txt found in $OUTDIR" >&2
  exit 1
fi

verify="$(rg -n "http.*?/api/auth/verify\\?token=" "$latest" | head -n 1 | sed -E 's/^[0-9]+://' | tr -d '\r' || true)"
if [ -z "$verify" ]; then
  echo "FAIL: could not extract verify URL from $latest" >&2
  exit 1
fi

echo "OK: outbox mail => $latest"
echo "OK: verify URL  => (hidden)"
echo

# Call verify and ensure redirect to /ui/welcome
hdr="$(mktemp)"
body="$(mktemp)"
curl -sS -D "$hdr" -o "$body" -i "$verify" >/dev/null || true

loc="$(rg -n "^Location:" "$hdr" | head -n 1 | sed -E 's/^Location:\s*//' | tr -d '\r' || true)"
status="$(head -n 1 "$hdr" | awk '{print $2}' || true)"

if [ "$status" != "302" ]; then
  echo "FAIL: verify expected 302, got $status" >&2
  cat "$hdr" | head -n 30 >&2
  exit 1
fi

if ! echo "$loc" | rg -q "/ui/welcome\\?tenantId="; then
  echo "FAIL: verify redirect location unexpected: $loc" >&2
  exit 1
fi

echo "OK ✅ verify redirect => /ui/welcome"
rm -f "$hdr" "$body"

echo "OK ✅ Auth provisioning flow (pilot) works"
