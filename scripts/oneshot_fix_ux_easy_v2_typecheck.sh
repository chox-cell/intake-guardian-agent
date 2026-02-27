#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BAK=".bak/$(date -u +%Y%m%dT%H%M%SZ)_fix_ux_easy_v2_typecheck"
mkdir -p "$BAK/src/api" "$BAK/src/ui"
cp -v src/api/admin-provision.ts "$BAK/src/api/admin-provision.ts.bak" 2>/dev/null || true
cp -v src/ui/routes.ts "$BAK/src/ui/routes.ts.bak" 2>/dev/null || true

node <<'NODE'
const fs = require("fs");
const path = require("path");

function patchAdminProvision() {
  const f = path.join(process.cwd(), "src/api/admin-provision.ts");
  if (!fs.existsSync(f)) {
    console.log("SKIP: missing", f);
    return;
  }
  let s = fs.readFileSync(f, "utf8");

  // Fix TS7006: add type to req param in helper
  // function __tenantKeyFromReq(req){
  s = s.replace(
    /function\s+__tenantKeyFromReq\s*\(\s*req\s*\)\s*\{/,
    "function __tenantKeyFromReq(req: any) {"
  );

  fs.writeFileSync(f, s, "utf8");
  console.log("OK: patched", f, "(typed req:any)");
}

function patchRoutes() {
  const f = path.join(process.cwd(), "src/ui/routes.ts");
  if (!fs.existsSync(f)) {
    console.log("SKIP: missing", f);
    return;
  }
  let s = fs.readFileSync(f, "utf8");

  // Fix TS2304: remove wrongly injected call in CSV route (workDir not in scope there)
  s = s.replace(/\n\s*__ensureEvidenceNotEmpty\s*\(\s*workDir\s*,[^\)]*\)\s*;\s*\n/g, "\n");

  // Now ensure we call __ensureEvidenceNotEmpty inside /ui/evidence.zip handler
  // We will locate the evidence.zip route block and inject after ticket rows are loaded.
  const re = /router\.get\(\s*["']\/ui\/evidence\.zip["'][\s\S]*?\n\s*\}\s*\)\s*;?/m;
  const m = s.match(re);
  if (!m) {
    console.log("WARN: could not find /ui/evidence.zip route block. (No injection done)");
    fs.writeFileSync(f, s, "utf8");
    return;
  }

  let block = m[0];
  if (block.includes("__ensureEvidenceNotEmpty(")) {
    console.log("SKIP: evidence.zip already calls __ensureEvidenceNotEmpty");
    fs.writeFileSync(f, s, "utf8");
    return;
  }

  // Find tickets variable inside the block
  // Prefer: const rows = ...
  let ticketsVar = null;
  let mm = block.match(/\bconst\s+(rows)\s*=\s*[^\n;]+;/);
  if (mm) ticketsVar = mm[1];

  if (!ticketsVar) {
    mm = block.match(/\bconst\s+(tickets)\s*=\s*[^\n;]+;/);
    if (mm) ticketsVar = mm[1];
  }

  // Find workDir inside the block
  let workDirVar = null;
  mm = block.match(/\bconst\s+(workDir)\s*=\s*[^\n;]+;/);
  if (mm) workDirVar = mm[1];

  if (!workDirVar) {
    // Some implementations use outDir + stamp directly, try to locate the folder creation as fallback
    // but safest is: do nothing if no workDir.
    console.log("WARN: could not detect workDir inside evidence.zip block. (No injection done)");
    fs.writeFileSync(f, s, "utf8");
    return;
  }

  if (!ticketsVar) {
    console.log("WARN: could not detect tickets/rows var inside evidence.zip block. (No injection done)");
    fs.writeFileSync(f, s, "utf8");
    return;
  }

  // Inject after the line that declares workDir OR after ticketsVar declaration if later.
  // We'll inject after workDir declaration line.
  const inj = `\n    __ensureEvidenceNotEmpty(${workDirVar}, ${ticketsVar} as any);\n`;
  block = block.replace(
    new RegExp(`(\\bconst\\s+${workDirVar}\\s*=\\s*[^\\n;]+;\\s*)`),
    `$1${inj}`
  );

  s = s.replace(re, block);
  fs.writeFileSync(f, s, "utf8");
  console.log("OK: patched", f, "(moved __ensureEvidenceNotEmpty into /ui/evidence.zip route)");
}

patchAdminProvision();
patchRoutes();
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Fixed UX EASY v2 typecheck errors"
echo "Backup: $BAK"
