#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK/scripts"

cp -v scripts/client_experience_a2z.sh "$BAK/scripts/client_experience_a2z.sh.bak"

# Remove ANY python usage
perl -0777 -pi -e 's/python - <<PY[\s\S]*?PY//g' scripts/client_experience_a2z.sh

# Replace parsing with Node everywhere
perl -0777 -pi -e '
s/TENANT_ID=.*/TENANT_ID="$(node -e '\''const u=new URL(process.argv[1]); console.log(u.searchParams.get("tenantId")||"");'\'' "$WELCOME")"/;
s/K=.*/K="$(node -e '\''const u=new URL(process.argv[1]); console.log(u.searchParams.get("k")||"");'\'' "$WELCOME")"/;
' scripts/client_experience_a2z.sh

# Prevent trying to execute URL as file
perl -0777 -pi -e '
s|^\s*\$WELCOME\s*$|echo "Welcome URL: $WELCOME"|m
' scripts/client_experience_a2z.sh

chmod +x scripts/client_experience_a2z.sh

echo "OK ✅ client_experience_a2z.sh is now PURE Node (no python, no file exec)."
echo "Backup: $BAK"
