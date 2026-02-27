#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> Fix routes.ts: ensure /api/auth mount is inside app scope"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

cp -v src/api/routes.ts "$BAK/routes.ts.bak"

# 1) Remove any existing /api/auth mount lines (wherever they are)
#    This avoids the bad top-level injected line.
perl -pi -e 's/^\s*app\.use\(\s*"\/api\/auth"[\s\S]*?\);\s*\n//mg' src/api/routes.ts

# 2) Ensure import exists (top of file). If missing, insert after last import.
if ! rg -n 'import\s+\{\s*authRouter\s*\}\s+from\s+"\.\/auth"' src/api/routes.ts >/dev/null 2>&1; then
  awk '
    BEGIN{last=0}
    /^import /{last=NR; print; next}
    {a[NR]=$0}
    END{
      for(i=1;i<=NR;i++){
        if(i==last+1 && last>0){
          print "import { authRouter } from \"./auth\";";
        }
        print a[i];
      }
      if(last==0){
        print "import { authRouter } from \"./auth\";";
      }
    }
  ' src/api/routes.ts > /tmp/routes.ts.$$ && mv /tmp/routes.ts.$$ src/api/routes.ts
fi

# 3) Insert mount INSIDE the scope: right after the webhook mount line (best signal).
#    If webhook mount not found, insert after the first app.use(...) line as fallback.
insert_line='  app.use("/api/auth", authRouter({ dataDir: process.env.DATA_DIR || "./data", appBaseUrl: process.env.APP_BASE_URL, emailFrom: process.env.EMAIL_FROM }));'

if rg -n 'app\.use\("\/api\/webhook"' src/api/routes.ts >/dev/null 2>&1; then
  awk -v INS="$insert_line" '
    BEGIN{done=0}
    {print}
    /app\.use\("\/api\/webhook"/ && done==0 {
      print INS
      done=1
    }
    END{
      if(done==0){
        exit 2
      }
    }
  ' src/api/routes.ts > /tmp/routes.ts.$$ && mv /tmp/routes.ts.$$ src/api/routes.ts
else
  awk -v INS="$insert_line" '
    BEGIN{done=0}
    {print}
    /app\.use\(/ && done==0 {
      print INS
      done=1
    }
    END{
      if(done==0){
        exit 3
      }
    }
  ' src/api/routes.ts > /tmp/routes.ts.$$ && mv /tmp/routes.ts.$$ src/api/routes.ts
fi

echo
echo "==> typecheck"
pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "==> SMOKE auth provisioning"
./scripts/smoke-auth-provisioning.sh

echo
echo "OK ✅ routes.ts scope fixed"
echo "Backups: $BAK"
