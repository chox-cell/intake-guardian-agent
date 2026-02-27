#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK/scripts"

cp -v scripts/client_experience_a2z.sh "$BAK/scripts/client_experience_a2z.sh.bak" 2>/dev/null || true

# Replace python URL parsing blocks with node (Node is available since pnpm dev works)
perl -0777 -pi -e '
s/TENANT_ID="\$\(python - <<PY[\s\S]*?PY\s*"\$WELCOME"\)\)"/TENANT_ID="$(node -e '\''const u=new URL(process.argv[1]); console.log(u.searchParams.get("tenantId")||"");'\'' "$WELCOME")"/g;

s/K="\$\(python - <<PY[\s\S]*?PY\s*"\$WELCOME"\)\)"/K="$(node -e '\''const u=new URL(process.argv[1]); console.log(u.searchParams.get("k")||"");'\'' "$WELCOME")"/g;
' scripts/client_experience_a2z.sh

chmod +x scripts/client_experience_a2z.sh

echo "OK ✅ Patched scripts/client_experience_a2z.sh to not require python."
echo "Backup: $BAK"
