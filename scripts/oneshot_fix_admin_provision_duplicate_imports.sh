#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Projects/intake-guardian-agent"
cd "$REPO"

FILE="src/api/admin-provision.ts"
BAK=".bak/$(date -u +%Y%m%dT%H%M%SZ)_fix_admin_provision_imports"
mkdir -p "$BAK"
cp "$FILE" "$BAK/admin-provision.ts.bak"

node <<'NODE'
const fs = require("fs");
const file = "src/api/admin-provision.ts";
let s = fs.readFileSync(file, "utf8");

// Remove ALL express type import lines (we will re-add a single correct one)
s = s.replace(/^\s*import\s+type\s*\{\s*[^}]*\}\s*from\s*["']express["'];\s*\r?\n/gm, "");

// Decide which types are needed based on usage
const usesResponse = /\bResponse\b/.test(s);
const usesRequest  = /\bRequest\b/.test(s);

// Insert a single import at top (after possible 'use strict' or comments)
let importLine = 'import type { Request' + (usesResponse ? ', Response' : '') + ' } from "express";\n';

if (usesRequest || usesResponse) {
  // place after shebang? (TS file won't have) so place at top.
  s = importLine + s;
}

fs.writeFileSync(file, s, "utf8");
console.log("PATCH_OK: admin-provision.ts de-duped express type imports");
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo "OK ✅ admin-provision.ts imports fixed"
echo "Backup: $BAK/admin-provision.ts.bak"
