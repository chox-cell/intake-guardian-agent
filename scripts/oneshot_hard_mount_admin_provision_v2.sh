#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}"
mkdir -p "$BAK/src/ui" "$BAK/scripts"

echo "==> One-shot v2: HARD mount /ui/admin/provision into UI mount function"
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

// 0) wipe legacy/broken import + router.get leftovers (from earlier patches)
s = s.replace(/^\s*import\s+\{\s*mountAdminProvisionUI\s*\}\s+from\s+["'][^"']*admin_provision_route[^"']*["'];?\s*$/gm, "");
s = s.replace(/mountAdminProvisionUI/g, "/*mountAdminProvisionUI_removed*/");

// remove any stray router.get for this route
s = s.replace(/^\s*router\.get\(\s*["']\/ui\/admin\/provision["'][^;]*;?\s*$/gm, "");

// 1) ensure EXACT import once (ESM .js)
const wantImport = `import { uiAdminProvision } from "./admin_provision_route.js";`;
const importRe = /^\s*import\s+\{\s*uiAdminProvision\s*\}\s+from\s+["']\.\/admin_provision_route(\.js)?["'];?\s*$/gm;

// remove all existing variants then add one clean import
s = s.replace(importRe, "");
// insert after last import
{
  const lines = s.split("\n");
  let lastImport = -1;
  for (let i=0;i<lines.length;i++){
    if (/^\s*import\b/.test(lines[i])) lastImport = i;
  }
  if (lastImport >= 0) lines.splice(lastImport+1, 0, wantImport);
  else lines.unshift(wantImport);
  s = lines.join("\n");
}

// 2) find the UI mount function and its host param (app variable)
let m =
  s.match(/export\s+function\s+(\w+)\s*\(\s*(\w+)\s*:\s*Express\s*\)\s*\{/)
  || s.match(/export\s+const\s+(\w+)\s*=\s*\(\s*(\w+)\s*:\s*Express\s*\)\s*=>\s*\{/);

if (!m) {
  console.error("FAIL: cannot find exported UI mount function (X: Express) { ... }");
  process.exit(2);
}

const host = m[2];

// 3) HARD insert route immediately after the opening brace of that function
// and remove any duplicates first
const routeLine = `${host}.get("/ui/admin/provision", uiAdminProvision);`;

// remove any existing mount attempts (host.get/use variations)
const dupRe = new RegExp(`^\\s*${host}\\.get\\(\\s*["']\\/ui\\/admin\\/provision["'][^;]*;\\s*$`, "gm");
s = s.replace(dupRe, "");

// locate the exact opening brace occurrence of the matched mount function
const idx = s.indexOf(m[0]);
if (idx < 0) process.exit(3);

const braceIdx = s.indexOf("{", idx);
if (braceIdx < 0) process.exit(4);

// if already present anywhere, don't double insert
if (!s.includes(routeLine)) {
  const inject =
`\n  // Founder-only: one-click provision page (Agency kit)\n  ${routeLine}\n`;
  s = s.slice(0, braceIdx + 1) + inject + s.slice(braceIdx + 1);
}

fs.writeFileSync(file, s, "utf8");
console.log(`OK: routes.ts hard-mounted /ui/admin/provision (host=${host})`);
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ hard mount applied"
echo "Backups: $BAK"
echo
echo "NEXT:"
echo "  1) Restart server:"
echo "     bash scripts/dev_7090.sh"
echo
echo "  2) Test route:"
echo "     curl -i 'http://127.0.0.1:7090/ui/admin/provision?adminKey=YOUR_ADMIN_KEY' | head"
