#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase30e OneShot (fix tenantId parsing in smoke-phase30.sh)"

FILE="scripts/smoke-phase30.sh"
[ -f "$FILE" ] || { echo "❌ $FILE not found"; exit 1; }

cp "$FILE" "${FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Robust tenantId parsing (works if tenantId is first or after &)
perl -0777 -i -pe '
s/TENANT_ID=.*\n/TENANT_ID="\$(echo "\$q" | sed -n "s/^tenantId=\\([^&]*\\).*/\\1/p; s/.*&tenantId=\\([^&]*\\).*/\\1/p")"\n/s
' "$FILE"

# Robust tenantKey parsing
perl -0777 -i -pe '
s/TENANT_KEY=.*\n/TENANT_KEY="\$(echo "\$q" | sed -n "s/^k=\\([^&]*\\).*/\\1/p; s/.*&k=\\([^&]*\\).*/\\1/p")"\n/s
' "$FILE"

chmod +x "$FILE"
echo "✅ Patched $FILE"
