#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${ts}"
mkdir -p "$BAK"

echo "==> One-shot B3.2b: Fix routes.ts import + insert /ui/admin/provision after router decl"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

cp -v src/ui/routes.ts "$BAK/src_ui_routes.ts.bak" >/dev/null

node - <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Fix/normalize import from admin_provision_route
// - remove mountAdminProvisionUI import
s = s.replace(
  /import\s*\{\s*mountAdminProvisionUI\s*\}\s*from\s*"\.\/admin_provision_route\.js";?\s*\n/g,
  ""
);

// - if there is any import from admin_provision_route, normalize to uiAdminProvision
s = s.replace(
  /import\s*\{\s*([^}]*)\s*\}\s*from\s*"\.\/admin_provision_route\.js";?\s*\n/g,
  (m, inside) => {
    const parts = inside.split(",").map(x => x.trim()).filter(Boolean);
    if (parts.includes("uiAdminProvision")) return 'import { uiAdminProvision } from "./admin_provision_route.js";\n';
    return 'import { uiAdminProvision } from "./admin_provision_route.js";\n';
  }
);

// - if still missing, add import after last import line
if (!s.includes('from "./admin_provision_route.js"')) {
  const importMatches = [...s.matchAll(/^import .*?;\s*$/gm)];
  if (importMatches.length > 0) {
    const last = importMatches[importMatches.length - 1];
    const insertPos = last.index + last[0].length;
    s = s.slice(0, insertPos) + '\nimport { uiAdminProvision } from "./admin_provision_route.js";' + s.slice(insertPos);
  } else {
    s = 'import { uiAdminProvision } from "./admin_provision_route.js";\n' + s;
  }
}

// 2) Remove any stray router.get("/ui/admin/provision"... ) lines (we will reinsert safely)
s = s.replace(/^\s*router\.get\("\/ui\/admin\/provision".*?\);\s*$/gm, "");

// 3) Remove any call to mountAdminProvisionUI(...) if present
s = s.replace(/^\s*mountAdminProvisionUI\([^)]*\);\s*$/gm, "");

// 4) Insert route after first "const router" declaration (guarantees scope)
const routerDecl = s.match(/^[ \t]*const[ \t]+router[ \t]*=[^\n]*$/m);
if (!routerDecl) {
  console.error("FAIL: Could not find 'const router =' in routes.ts");
  process.exit(1);
}
const idx = s.indexOf(routerDecl[0]);
const lineEnd = s.indexOf("\n", idx);
const indent = (routerDecl[0].match(/^([ \t]*)/) || ["",""])[1];
const injection = `${indent}router.get("/ui/admin/provision", uiAdminProvision);\n`;
s = s.slice(0, lineEnd + 1) + injection + s.slice(lineEnd + 1);

// 5) Ensure we didn't accidentally keep mountAdminProvisionUI import anywhere
s = s.replace(/mountAdminProvisionUI/g, "/*mountAdminProvisionUI_removed*/");

fs.writeFileSync(file, s, "utf8");
console.log("OK: routes.ts patched (import fixed + route inserted after router decl)");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json

echo
echo "OK ✅ B3.2b applied"
echo "Backup: $BAK"
