#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> One-shot B3.2c: fix routes.ts import crash + mount /ui/admin/provision"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

cp -v src/ui/routes.ts "$BAK/src_ui_routes.ts.bak" >/dev/null

node - <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Remove the bad import line (mountAdminProvisionUI)
s = s.replace(
  /^\s*import\s*\{\s*mountAdminProvisionUI\s*\}\s*from\s*"\.\/admin_provision_route\.js";\s*\n?/m,
  ""
);

// 2) Ensure we import uiAdminProvision
if (!s.match(/import\s*\{\s*uiAdminProvision\s*\}\s*from\s*"\.\/admin_provision_route\.js";/)) {
  // Insert after the last import statement
  const imports = [...s.matchAll(/^\s*import .*?;\s*$/gm)];
  if (imports.length) {
    const last = imports[imports.length - 1];
    const pos = last.index + last[0].length;
    s = s.slice(0, pos) + `\nimport { uiAdminProvision } from "./admin_provision_route.js";` + s.slice(pos);
  } else {
    s = `import { uiAdminProvision } from "./admin_provision_route.js";\n` + s;
  }
}

// 3) Remove any calls to mountAdminProvisionUI(...) if they exist
s = s.replace(/^\s*mountAdminProvisionUI\([^)]*\);\s*$/gm, "");

// 4) Mount route using the SAME router/app variable that is already used for /ui/welcome
// We look for:   X.get("/ui/welcome" ... )  OR  X.get('/ui/welcome' ... )
const m = s.match(/^\s*([A-Za-z_$][\w$]*)\.(get|use)\(\s*['"]\/ui\/welcome['"]/m);
if (!m) {
  console.error("FAIL: Could not find existing mount for /ui/welcome to detect router variable.");
  console.error("Hint: routes.ts structure changed; search manually for /ui/welcome and add admin provision next to it.");
  process.exit(1);
}
const routerVar = m[1];

// 5) If not already mounted, insert admin provision next to welcome mount
if (!s.includes(`"${"/ui/admin/provision"}"`) && !s.includes(`'${"/ui/admin/provision"}'`)) {
  // Insert AFTER the first /ui/welcome mount line
  const lines = s.split("\n");
  let inserted = false;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes(`/ui/welcome`) && lines[i].includes(`${routerVar}.`)) {
      lines.splice(i + 1, 0, `${routerVar}.get("/ui/admin/provision", uiAdminProvision);`);
      inserted = true;
      break;
    }
  }
  if (!inserted) {
    console.error("FAIL: Found router var but could not insert after /ui/welcome line.");
    process.exit(2);
  }
  s = lines.join("\n");
}

fs.writeFileSync(file, s, "utf8");
console.log(`OK: routes.ts patched (routerVar=${routerVar})`);
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ B3.2c applied"
echo "Backup: $BAK"
