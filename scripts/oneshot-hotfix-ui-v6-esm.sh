#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_hotfix_ui_v6/${TS}"
mkdir -p "$BAK"

echo "==> Hotfix UI v6 (ESM): remove require() @ $(pwd)"
echo "==> backups -> $BAK"

cp -a src/api/ui_v6.ts "$BAK/ui_v6.ts.bak" 2>/dev/null || true

node <<'NODE'
import fs from "fs";

const p = "src/api/ui_v6.ts";
let s = fs.readFileSync(p, "utf8");

// 1) Ensure we have an ESM import for requireTenantKey
if (!s.includes('from "./tenant-key.js"')) {
  // insert after first import line
  s = s.replace(
    /^(import[^\n]*\n)/m,
    `$1import { requireTenantKey } from "./tenant-key.js";\n`
  );
}

// 2) Remove the runtime require line (and variants)
s = s.replace(
  /^\s*const\s*\{\s*requireTenantKey\s*\}\s*=\s*require\(["']\.\/tenant-key\.js["']\)\s*as\s*any;\s*\n/mg,
  ""
);
s = s.replace(
  /^\s*const\s*\{\s*requireTenantKey\s*\}\s*=\s*require\(["']\.\/tenant-key\.js["']\);\s*\n/mg,
  ""
);

// 3) Remove any "require(" occurrences defensively (we shouldn't have any left)
if (/\brequire\(/.test(s)) {
  throw new Error("Found leftover require() in ui_v6.ts — aborting for safety.");
}

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo "✅ Done. Now run: pnpm dev"
