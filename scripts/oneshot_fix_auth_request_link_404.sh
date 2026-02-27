#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> Fix Auth 404: /api/auth/request-link"
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
backup "src/server.ts"
backup "scripts/smoke-auth-provisioning.sh"

mkdir -p src/api src/lib data/outbox

# -----------------------------
# 1) Add minimal auth router
# -----------------------------
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

    // simple token (dev). Later: store + TTL + single-use.
    const token = crypto.randomBytes(24).toString("hex");
    const link = `${appBaseUrl}/ui/login?token=${encodeURIComponent(token)}&email=${encodeURIComponent(email)}`;

    // In dev: always write to outbox (works without SMTP)
    writeOutbox(dataDirAbs, emailFrom, email, link);

    return res.status(200).json({ ok: true });
  });

  return r;
}
TS

# -----------------------------
# 2) Mount router in API routes
# -----------------------------
if rg -n "authRouter" src/api/routes.ts >/dev/null 2>&1; then
  echo "OK: authRouter already referenced in src/api/routes.ts"
else
  # Add import
  perl -0777 -pi -e '
    if ($_ !~ /from\s+"\.\.\/api\/auth"|from\s+"\.\.\/api\/auth\.ts"|from\s+"\.\.\/auth"|from\s+"\.\.\/auth\.ts"|from\s+"\.\.\/api\/auth"/) {
      s/(^import[\s\S]*?\n)(?!import)/$1import { authRouter } from ".\/auth";\n/m;
    }
  ' src/api/routes.ts
fi

# Add mounting line near other app.use lines (best-effort)
if rg -n 'app\.use\("/api/auth"' src/api/routes.ts >/dev/null 2>&1; then
  echo "OK: /api/auth already mounted"
else
  perl -0777 -pi -e '
    # insert after the first app.use("/api/..") or near end of register function
    if ($_ =~ /app\.use\(\"\/api\/webhook\"/s) {
      s/(app\.use\(\"\/api\/webhook\"[\s\S]*?\);\n)/$1\n  app.use(\"\/api\/auth\", authRouter({ dataDir: process.env.DATA_DIR || \"\\.\\/data\", appBaseUrl: process.env.APP_BASE_URL, emailFrom: process.env.EMAIL_FROM }));\n/s;
    } else {
      # fallback: append at end of file (inside exported function if exists)
      s/(\n\}\s*$)/\n\n  app.use(\"\/api\/auth\", authRouter({ dataDir: process.env.DATA_DIR || \"\\.\\/data\", appBaseUrl: process.env.APP_BASE_URL, emailFrom: process.env.EMAIL_FROM }));\n$1/s;
    }
  ' src/api/routes.ts
fi

# -----------------------------
# 3) Ensure smoke-auth-provisioning expects correct endpoint
# -----------------------------
if [ -f scripts/smoke-auth-provisioning.sh ]; then
  perl -pi -e 's#/api/auth/request-link#/api/auth/request-link#g' scripts/smoke-auth-provisioning.sh
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
