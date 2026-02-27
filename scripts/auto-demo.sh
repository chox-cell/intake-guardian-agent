#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"

echo "==> [1] Get fresh tenant link"
OUT="$(BASE_URL="$BASE_URL" ./scripts/demo-keys.sh | tee /dev/stderr | awk 'NF{last=$0} END{print ""}')"

# Extract the printed UI URL from stderr output by re-running and capturing stdout lines
UI_URL="$(BASE_URL="$BASE_URL" ./scripts/demo-keys.sh 2>/dev/null | grep -E '^http' | head -n 1 || true)"
CSV_URL="$(BASE_URL="$BASE_URL" ./scripts/demo-keys.sh 2>/dev/null | grep -E '^http' | tail -n 1 || true)"

# Fallback: parse from the first run by scanning the terminal history is not reliable, so we keep it simple.
echo
echo "==> [2] If you want to create a ticket now, run:"
echo "TENANT_ID=... TENANT_KEY=... curl -sS \"$BASE_URL/api/adapters/email/sendgrid?tenantId=TENANT_ID\" -H \"x-tenant-key: TENANT_KEY\" -F 'from=employee@corp.local' -F 'subject=VPN broken' -F 'text=VPN down' | jq ."
