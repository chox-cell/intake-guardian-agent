#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${ts}"
mkdir -p "$BAK"

echo "==> One-shot B3.2: Fix routes.ts import + ensure router scope"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

cp -v src/ui/routes.ts "$BAK/src_ui_routes.ts.bak" >/dev/null

node - <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Fix wrong import name if present
s = s.replace(
  /import\s*\{\s*mountAdminProvisionUI\s*\}\s*from\s*"\.\/admin_provision_route\.js";?/g,
  'import { uiAdminProvision } from "./admin_provision_route.js";'
);

// If it imported both, keep only uiAdminProvision (best effort)
s = s.replace(
  /import\s*\{\s*([^}]*)\s*\}\s*from\s*"\.\/admin_provision_route\.js";?/g,
  (m, inside) => {
    const parts = inside.split(",").map(x => x.trim()).filter(Boolean);
    if (parts.includes("uiAdminProvision")) return 'import { uiAdminProvision } from "./admin_provision_route.js";';
    if (parts.includes("mountAdminProvisionUI")) return 'import { uiAdminProvision } from "./admin_provision_route.js";';
    return m;
  }
);

// 2) Remove any stray "router.get('/ui/admin/provision'...)" lines that are outside scope.
// We'll re-insert it safely inside the main UI mount function.
s = s.replace(/^\s*router\.get\("\/ui\/admin\/provision".*?\);\s*$/gm, "");

// 3) Insert route registration next to other /ui routes.
// Heuristic: find a line that registers "/ui/pilot" or "/ui/welcome" and insert after it.
// Fallback: insert after the first occurrence of `router.get("/ui/` block.
let inserted = false;

function insertAfter(pattern) {
  const idx = s.search(pattern);
  if (idx === -1) return false;

  // find end of that line
  const lineEnd = s.indexOf("\n", idx);
  const before = s.slice(0, lineEnd + 1);
  const after = s.slice(lineEnd + 1);
  const injection = `  router.get("/ui/admin/provision", uiAdminProvision);\n`;
  if (before.includes('router.get("/ui/admin/provision"')) return true;
  s = before + injection + after;
  inserted = true;
  return true;
}

insertAfter(/router\.get\("\/ui\/pilot"/);
if (!inserted) insertAfter(/router\.get\("\/ui\/welcome"/);
if (!inserted) insertAfter(/router\.get\("\/ui\//);

if (!inserted) {
  console.error("FAIL: Could not find a place to insert /ui/admin/provision route safely.");
  process.exit(1);
}

// 4) Ensure we actually reference uiAdminProvision (import must exist)
if (!s.includes('import { uiAdminProvision } from "./admin_provision_route.js";')) {
  // Try to add it near top (after other ui imports)
  const marker = s.match(/import .*from "\.\/start_route\.js";\n/);
  if (marker) {
    s = s.replace(marker[0], marker[0] + 'import { uiAdminProvision } from "./admin_provision_route.js";\n');
  } else {
    s = 'import { uiAdminProvision } from "./admin_provision_route.js";\n' + s;
  }
}

fs.writeFileSync(file, s, "utf8");
console.log("OK: routes.ts fixed (import + router scope insertion)");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json

echo
echo "OK ✅ B3.2 applied"
echo "Backup: $BAK"
