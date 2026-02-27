#!/usr/bin/env bash
set -euo pipefail
REPO="${REPO:-$HOME/Projects/intake-guardian-agent}"
cd "$REPO"

ts_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
BK=".bak/${ts_utc}_fix_server_dupe_express_imports"
mkdir -p "$BK"
cp -a src/server.ts "$BK/server.ts"

node <<'NODE'
const fs = require("fs");
const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Remove any express type import lines
s = s.replace(/^\s*import\s+type\s+\{[^}]*\}\s+from\s+["']express["'];\s*\r?\n/gm, "");

// 2) Insert ONE canonical import type line near the top (after first import line)
const lines = s.split(/\r?\n/);
let inserted = false;
const out = [];

for (let i = 0; i < lines.length; i++) {
  out.push(lines[i]);
  if (!inserted && lines[i].startsWith("import ")) {
    // insert right after first import statement
    out.push('import type { Request, Response, NextFunction } from "express";');
    inserted = true;
  }
}

s = out.join("\n");

// 3) If file had no imports at all (unlikely), prepend it
if (!inserted) {
  s = 'import type { Request, Response, NextFunction } from "express";\n' + s;
}

fs.writeFileSync(file, s, "utf8");
console.log("OK: normalized express type imports in", file);
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ v8.1 applied (server.ts duplicate express type imports fixed)"
echo "Backup: $BK"
