#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}"
mkdir -p "$BAK/src/ui" "$BAK/scripts"

echo "==> One-shot: Fix /ui/admin/provision mount (routes.ts)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

FILE="src/ui/routes.ts"
if [ ! -f "$FILE" ]; then
  echo "FAIL: missing $FILE" >&2
  exit 1
fi

cp -a "$FILE" "$BAK/src/ui/routes.ts.bak"

node <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Remove any broken/legacy import references
s = s.replace(/^\s*import\s+\{\s*mountAdminProvisionUI\s*\}\s+from\s+["'][^"']*admin_provision_route[^"']*["'];?\s*$/gm, "");
s = s.replace(/mountAdminProvisionUI/g, "/*mountAdminProvisionUI_removed*/");

// 2) Remove duplicate uiAdminProvision imports (keep one, ESM .js)
s = s.replace(/^\s*import\s+\{\s*uiAdminProvision\s*\}\s+from\s+["']\.\/admin_provision_route["'];?\s*$/gm, "");
s = s.replace(/^\s*import\s+\{\s*uiAdminProvision\s*\}\s+from\s+["']\.\/admin_provision_route\.js["'];?\s*$/gm, "");

// 3) Insert the correct import near top (after type imports is fine too)
const importLine = `import { uiAdminProvision } from "./admin_provision_route.js";\n`;
if (!s.includes(importLine.trim())) {
  // insert after the last import line
  const lines = s.split("\n");
  let lastImportIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*import\b/.test(lines[i])) lastImportIdx = i;
  }
  if (lastImportIdx >= 0) {
    lines.splice(lastImportIdx + 1, 0, importLine.trimEnd());
    s = lines.join("\n");
  } else {
    s = importLine + s;
  }
}

// 4) Find the exported mount function and its host param
// supports: export function mountUI(app: Express) { ... }
// or: export function mountUIRoutes(app: Express) { ... }
let m = s.match(/export\s+function\s+(mountUI|mountUIRoutes|mountRoutes|mountUi)\s*\(\s*(\w+)\s*:\s*Express\s*\)/);
if (!m) {
  // alternative: export const mountUI = (app: Express) => { ... }
  m = s.match(/export\s+const\s+(mountUI|mountUIRoutes|mountRoutes|mountUi)\s*=\s*\(\s*(\w+)\s*:\s*Express\s*\)\s*=>/);
}
if (!m) {
  console.error("FAIL: could not find exported UI mount function taking (X: Express).");
  console.error("Hint: open src/ui/routes.ts and search for 'export function mount' and ensure it takes (app: Express).");
  process.exit(2);
}
const host = m[2];

// 5) Ensure route is mounted INSIDE the mount function body
// Strategy: insert after the first existing /ui/ route mount line, else right after the opening brace.
const funcName = m[1];
const funcIdx = s.indexOf(m[0]);
if (funcIdx < 0) process.exit(3);

// Find the opening brace of the function body
let braceIdx = s.indexOf("{", funcIdx);
if (braceIdx < 0) {
  console.error("FAIL: could not locate '{' for mount function body");
  process.exit(4);
}

// Determine insertion point: after first `${host}.get("/ui/` or `${host}.use("/ui`
const bodyStart = braceIdx + 1;
const bodySlice = s.slice(bodyStart);

let insertOffset = -1;
let routeMatch = bodySlice.match(new RegExp(`${host}\\.(get|use)\\(\\s*["']\\/ui\\/`, "m"));
if (routeMatch) {
  insertOffset = bodyStart + routeMatch.index;
  // insert *before* that first ui route, so admin route is early
} else {
  insertOffset = bodyStart; // directly after opening brace
}

// Avoid duplicate mount
if (!s.includes(`${host}.get("/ui/admin/provision"`)) {
  const injection =
`\n  // Admin: provision a demo client kit (Founder only)\n  ${host}.get("/ui/admin/provision", uiAdminProvision);\n`;
  s = s.slice(0, insertOffset) + injection + s.slice(insertOffset);
}

// 6) Clean any stray "router.get" lines that may exist from previous patches
s = s.replace(/^\s*router\.get\(\s*["']\/ui\/admin\/provision["'][^)]*\)\s*;?\s*$/gm, `  ${host}.get("/ui/admin/provision", uiAdminProvision);`);

// 7) Final sanity: do not leave duplicate importLine
// (already removed above; this is extra safety)
const importRe = /^import\s+\{\s*uiAdminProvision\s*\}\s+from\s+["']\.\/admin_provision_route\.js["'];?\s*$/gm;
const imports = s.match(importRe) || [];
if (imports.length > 1) {
  // keep first
  let seen = 0;
  s = s.replace(importRe, (line) => (++seen === 1 ? line : ""));
}

fs.writeFileSync(file, s, "utf8");
console.log(`OK: patched ${file} (mounted /ui/admin/provision on host=${host})`);
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Fix applied"
echo "Backups: $BAK"
echo
echo "NEXT:"
echo "  1) Start server:"
echo "     bash scripts/dev_7090.sh"
echo
echo "  2) Open (replace ADMIN_KEY):"
echo "     http://127.0.0.1:7090/ui/admin/provision?adminKey=YOUR_ADMIN_KEY"
