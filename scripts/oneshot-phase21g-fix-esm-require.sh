#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts(){ date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase21g_$(ts)"
echo "==> Phase21g OneShot (fix ESM require in ui/routes.ts) @ $ROOT"
mkdir -p "$BAK"
cp -R src "$BAK/src" 2>/dev/null || true
echo "✅ backup -> $BAK"

node - <<'NODE'
const fs = require("fs");
const p = "src/ui/routes.ts";
let s = fs.readFileSync(p, "utf8");

// 1) Ensure ESM import exists (no require)
if (!s.includes('from "node:crypto"') && !s.includes("from 'node:crypto'")) {
  // Insert after last import line
  const lines = s.split("\n");
  let lastImport = -1;
  for (let i=0;i<lines.length;i++){
    if (lines[i].startsWith("import ")) lastImport = i;
  }
  const insertAt = lastImport >= 0 ? lastImport+1 : 0;
  lines.splice(insertAt, 0, `import { timingSafeEqual } from "node:crypto";`);
  s = lines.join("\n");
}

// 2) Replace constantTimeEq implementation to avoid require()
const re = /function\s+constantTimeEq\s*\([\s\S]*?\n}\n/;
// If we can't find the function, we still patch common inline patterns later.
const replacement =
`function constantTimeEq(a: string, b: string) {
  // ESM-safe constant-time-ish compare using node:crypto
  // Normalize to same length buffers to keep timingSafeEqual happy.
  const aa = Buffer.from(String(a), "utf8");
  const bb = Buffer.from(String(b), "utf8");
  const len = Math.max(aa.length, bb.length, 1);
  const a2 = Buffer.alloc(len);
  const b2 = Buffer.alloc(len);
  aa.copy(a2);
  bb.copy(b2);
  return timingSafeEqual(a2, b2) && aa.length === bb.length;
}
`;

if (re.test(s)) {
  s = s.replace(re, replacement + "\n");
} else {
  // Fallback: kill any `require("crypto")` usage if present and inject function at top
  s = s.replace(/const\s+\{\s*timingSafeEqual\s*\}\s*=\s*require\(["']crypto["']\);\s*/g, "");
  if (!s.includes("function constantTimeEq")) {
    // Put after imports
    const lines = s.split("\n");
    let lastImport = -1;
    for (let i=0;i<lines.length;i++){
      if (lines[i].startsWith("import ")) lastImport = i;
    }
    const insertAt = lastImport >= 0 ? lastImport+1 : 0;
    lines.splice(insertAt, 0, "", replacement.trim(), "");
    s = lines.join("\n");
  }
}

// 3) Remove any leftover `require(` in this file (safety)
s = s.replace(/\brequire\(/g, "/*require_blocked*/(");

fs.writeFileSync(p, s);
console.log("✅ patched src/ui/routes.ts (ESM-safe constantTimeEq)");
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase21g installed."
echo "Now:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
