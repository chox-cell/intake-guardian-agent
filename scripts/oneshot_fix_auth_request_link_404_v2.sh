#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> Fix Auth 404 (v2): /api/auth/request-link"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

backup () {
  local p="$1"
  if [ -f "$p" ]; then
    mkdir -p "$BAK/$(dirname "$p")"
    cp -v "$p" "$BAK/$p.bak"
  fi
}

backup "src/api/routes.ts"
backup "scripts/smoke-auth-provisioning.sh"

mkdir -p src/api data/outbox

# 1) Create auth router (idempotent overwrite)
cat > src/api/auth.ts <<'TS'
import { Router } from "express";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

function nowUtc() {
  return new Date().toISOString();
}

function safeMkdir(p: string) {
  try { fs.mkdirSync(p, { recursive: true }); } catch {}
}

function writeOutbox(dataDirAbs: string, emailFrom: string, emailTo: string, link: string) {
  const outDir = path.join(dataDirAbs, "outbox");
  safeMkdir(outDir);
  const stamp = nowUtc().replace(/[:.]/g, "-");
  const file = path.join(outDir, `${stamp}__${emailTo.replace(/[^a-zA-Z0-9+@._-]/g, "_")}.txt`);
  const body =
`FROM: ${emailFrom}
TO:   ${emailTo}
DATE: ${nowUtc()}

LOGIN LINK:
${link}
`;
  fs.writeFileSync(file, body, "utf8");
}

export function authRouter(opts?: { dataDir?: string; appBaseUrl?: string; emailFrom?: string }) {
  const r = Router();

  const dataDirAbs =
    (opts?.dataDir && path.isAbsolute(opts.dataDir)) ? opts.dataDir :
    path.resolve(process.cwd(), opts?.dataDir || "./data");

  const appBaseUrl = (opts?.appBaseUrl || process.env.APP_BASE_URL || "http://127.0.0.1:7090").replace(/\/+$/,"");
  const emailFrom = (opts?.emailFrom || process.env.EMAIL_FROM || "no-reply@local").toString();

  // POST /api/auth/request-link  { email }
  r.post("/request-link", (req, res) => {
    const email = String((req?.body?.email || "")).trim().toLowerCase();
    if (!email) return res.status(400).json({ ok: false, error: "missing_email" });

    const token = crypto.randomBytes(24).toString("hex");
    const link = `${appBaseUrl}/ui/login?token=${encodeURIComponent(token)}&email=${encodeURIComponent(email)}`;

    // DEV: always write to outbox (works without SMTP)
    writeOutbox(dataDirAbs, emailFrom, email, link);

    return res.status(200).json({ ok: true });
  });

  return r;
}
TS

# 2) Patch routes.ts safely:
#    - ensure import exists
#    - ensure app.use("/api/auth", authRouter(...)) exists
if [ ! -f src/api/routes.ts ]; then
  echo "FAIL: src/api/routes.ts not found" >&2
  exit 1
fi

# 2a) Ensure import line exists
if ! rg -n 'authRouter' src/api/routes.ts >/dev/null 2>&1; then
  # Insert after last import line
  awk '
    BEGIN{added=0}
    /^import /{print; lastImport=NR; next}
    {lines[NR]=$0}
    END{
      for(i=1;i<=NR;i++){
        if(i==lastImport+1 && added==0){
          print "import { authRouter } from \"./auth\";";
          added=1;
        }
        print lines[i];
      }
      if(lastImport==0 && added==0){
        # no imports found, prepend
        print "import { authRouter } from \"./auth\";";
      }
    }
  ' src/api/routes.ts > /tmp/routes.ts.$$ && mv /tmp/routes.ts.$$ src/api/routes.ts
fi

# 2b) Ensure mount exists
if rg -n 'app\.use\("\/api\/auth"' src/api/routes.ts >/dev/null 2>&1; then
  echo "OK: /api/auth already mounted"
else
  # Insert mount right after webhook mount if present, otherwise near end of register function.
  awk '
    BEGIN{done=0}
    {print}
    /app\.use\("\/api\/webhook"/ && done==0 {
      print "  app.use(\"/api/auth\", authRouter({ dataDir: process.env.DATA_DIR || \"./data\", appBaseUrl: process.env.APP_BASE_URL, emailFrom: process.env.EMAIL_FROM }));"
      done=1
    }
    END{
      if(done==0){
        # fallback: append (best-effort)
        print ""
        print "  app.use(\"/api/auth\", authRouter({ dataDir: process.env.DATA_DIR || \"./data\", appBaseUrl: process.env.APP_BASE_URL, emailFrom: process.env.EMAIL_FROM }));"
      }
    }
  ' src/api/routes.ts > /tmp/routes.ts.$$ && mv /tmp/routes.ts.$$ src/api/routes.ts
fi

# 3) Smoke script keeps using /api/auth/request-link (already)
if [ -f scripts/smoke-auth-provisioning.sh ]; then
  # no-op; just ensure it references correct endpoint
  true
fi

echo
echo "==> typecheck"
pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "==> SMOKE auth provisioning"
./scripts/smoke-auth-provisioning.sh

echo
echo "OK ✅ Fixed: /api/auth/request-link now returns 200 (writes data/outbox)"
echo "Backups: $BAK"
