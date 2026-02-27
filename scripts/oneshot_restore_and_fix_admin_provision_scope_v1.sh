#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
BAK=".bak/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BAK"
echo "==> One-shot: RESTORE server.ts then fix /api/admin/provision (scope-safe + field aliases)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

# 0) Find latest backup that contains server.ts.bak and restore it
LATEST_BAK="$(ls -1dt .bak/* 2>/dev/null | head -n 1 || true)"
if [[ -z "${LATEST_BAK}" ]]; then
  echo "FAIL: No .bak directory found."
  exit 2
fi

# Prefer the specific backup created by the broken patch if present
PREFERRED=".bak/20260115T001104Z/server.ts.bak"
if [[ -f "$PREFERRED" ]]; then
  SRC="$PREFERRED"
else
  # fall back: find any server.ts.bak
  SRC="$(ls -1t .bak/*/server.ts.bak 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${SRC:-}" || ! -f "$SRC" ]]; then
  echo "FAIL: Could not locate any backup file .bak/*/server.ts.bak"
  exit 2
fi

cp -a src/server.ts "$BAK/server.ts.pre_restore.bak"
cp -a "$SRC" src/server.ts
echo "OK: restored src/server.ts from $SRC"

# 1) Patch ONLY inside the /api/admin/provision handler
node <<'NODE'
const fs = require("fs");

const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

// Locate the handler block for /api/admin/provision
// We match: app.post("/api/admin/provision", ... (req,res)=>{ ... });
const re = /app\.post\(\s*["']\/api\/admin\/provision["'][\s\S]*?\(\s*req\s*,\s*res\s*\)\s*=>\s*\{([\s\S]*?)\n\}\s*\)\s*;?/m;
const m = s.match(re);
if (!m) {
  console.error("FAIL: Could not find app.post('/api/admin/provision'...(req,res)=>{...}) in src/server.ts");
  process.exit(2);
}

let body = m[1];

// Remove any previously injected "providedKey" or "expected" blocks if present (defensive)
body = body.replace(/\/\/ Accept admin key[\s\S]*?unauthorized"\s*\}\);\s*\}\n/gm, "");
body = body.replace(/const\s+providedKey\s*=[\s\S]*?;\n/gm, "");
body = body.replace(/const\s+expected\s*=[\s\S]*?;\n/gm, "");

// Insert robust key extraction + auth check at the TOP of handler body (first non-empty line)
const inject = `
  // Admin auth (dev-friendly): accept adminKey from body OR query OR headers
  const providedKey =
    (req.body && (req.body.adminKey || req.body.key)) ||
    (req.query && (req.query.adminKey || req.query.key)) ||
    req.header("x-admin-key") ||
    req.header("x-admin") ||
    "";

  const expected = process.env.ADMIN_KEY || "";
  if (!expected || String(providedKey) !== String(expected)) {
    return res.status(401).json({ ok: false, error: "unauthorized" });
  }

  // Field aliases: UI sends {workspaceName, agencyEmail}; curl sends {tenantName, email}
  if (req.body) {
    req.body.tenantName = req.body.tenantName || req.body.workspaceName;
    req.body.email = req.body.email || req.body.agencyEmail;
  }
`;

const lines = body.split("\n");
let idx = 0;
while (idx < lines.length && lines[idx].trim() === "") idx++;
lines.splice(idx, 0, inject.trimEnd());
body = lines.join("\n");

// Replace handler body in file
s = s.replace(re, (full) => full.replace(m[1], body));

fs.writeFileSync(file, s, "utf8");
console.log("OK: patched src/server.ts (auth check inside handler + field aliases)");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Restore+Fix applied"
echo "Backup: $BAK"
echo
echo "NEXT:"
echo "  1) Restart server:"
echo "     bash scripts/dev_7090.sh"
echo
echo "  2) Test (should be 200/201):"
echo "     curl -i -X POST http://127.0.0.1:7090/api/admin/provision \\"
echo "       -H 'content-type: application/json' \\"
echo "       -d '{\"adminKey\":\"dev_admin_key_123\",\"workspaceName\":\"salam\",\"agencyEmail\":\"choxmou@gmail.com\"}' | head -n 20"
