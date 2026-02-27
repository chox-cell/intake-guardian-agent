#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> One-shot B3.2d: HARD fix routes.ts (remove mountAdminProvisionUI import/calls; mount /ui/admin/provision)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

cp -v src/ui/routes.ts "$BAK/src_ui_routes.ts.bak" >/dev/null

node - <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 1) Remove any import of mountAdminProvisionUI
s = s.replace(
  /^\s*import\s*\{\s*mountAdminProvisionUI\s*\}\s*from\s*["']\.\/admin_provision_route\.js["'];\s*\n?/gm,
  ""
);

// 2) Remove any calls to mountAdminProvisionUI(...)
s = s.replace(/^\s*mountAdminProvisionUI\([^)]*\);\s*$/gm, "");

// 3) Replace any remaining identifier mentions to avoid runtime import errors
s = s.replace(/\bmountAdminProvisionUI\b/g, "/*mountAdminProvisionUI_removed*/");

// 4) Ensure correct import exists
const importLine = `import { uiAdminProvision } from "./admin_provision_route.js";`;
if (!s.includes(importLine)) {
  const imports = [...s.matchAll(/^\s*import .*?;\s*$/gm)];
  if (imports.length) {
    const last = imports[imports.length - 1];
    const pos = last.index + last[0].length;
    s = s.slice(0, pos) + `\n${importLine}` + s.slice(pos);
  } else {
    s = `${importLine}\n` + s;
  }
}

// 5) Detect the router/app variable by finding the first ".get('/ui/" or ".use('/ui/"
const m = s.match(/^\s*([A-Za-z_$][\w$]*)\.(get|use)\(\s*["']\/ui\//m);
if (!m) {
  console.error("FAIL: Could not detect router/app var (no .get('/ui/' or .use('/ui/' found).");
  console.error("Open src/ui/routes.ts and search for .get(\"/ui/ or .use(\"/ui/ and add admin provision next to it.");
  process.exit(1);
}
const host = m[1];

// 6) If route not already present, insert it right after the first UI mount line we found
if (!s.match(/\/ui\/admin\/provision/)) {
  const lines = s.split("\n");
  let inserted = false;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes(`${host}.`) && (lines[i].includes(`"/ui/`) || lines[i].includes(`'/ui/`))) {
      lines.splice(i + 1, 0, `${host}.get("/ui/admin/provision", uiAdminProvision);`);
      inserted = true;
      break;
    }
  }
  if (!inserted) {
    console.error("FAIL: Host var detected but insertion point not found.");
    process.exit(2);
  }
  s = lines.join("\n");
}

fs.writeFileSync(file, s, "utf8");
console.log(`OK: routes.ts patched (host=${host})`);
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ B3.2d applied"
echo "Backup: $BAK"
