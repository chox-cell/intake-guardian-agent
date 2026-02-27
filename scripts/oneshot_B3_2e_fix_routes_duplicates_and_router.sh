#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/$TS"
mkdir -p "$BAK"

echo "==> One-shot B3.2e: fix routes.ts (remove duplicate uiAdminProvision import, replace router->host)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

cp -v src/ui/routes.ts "$BAK/src_ui_routes.ts.bak" >/dev/null

node - <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// 0) remove any leftover mountAdminProvisionUI import/calls
s = s.replace(
  /^\s*import\s*\{\s*mountAdminProvisionUI\s*\}\s*from\s*["']\.\/admin_provision_route\.js["'];\s*\n?/gm,
  ""
);
s = s.replace(/^\s*mountAdminProvisionUI\([^)]*\);\s*$/gm, "");
s = s.replace(/\bmountAdminProvisionUI\b/g, "/*mountAdminProvisionUI_removed*/");

// 1) remove duplicate uiAdminProvision import WITHOUT .js (keep .js variant)
s = s.replace(
  /^\s*import\s*\{\s*uiAdminProvision\s*\}\s*from\s*["']\.\/admin_provision_route["'];\s*\n?/gm,
  ""
);

// 2) ensure the .js import exists exactly once
const goodImport = `import { uiAdminProvision } from "./admin_provision_route.js";`;
const count = (s.match(new RegExp(goodImport.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) || []).length;
if (count === 0) {
  // insert after last import
  const imports = [...s.matchAll(/^\s*import .*?;\s*$/gm)];
  if (imports.length) {
    const last = imports[imports.length - 1];
    const pos = last.index + last[0].length;
    s = s.slice(0, pos) + `\n${goodImport}` + s.slice(pos);
  } else {
    s = `${goodImport}\n` + s;
  }
} else if (count > 1) {
  // keep first, remove the rest
  let first = true;
  s = s.split("\n").filter(line => {
    if (line.trim() === goodImport) {
      if (first) { first = false; return true; }
      return false;
    }
    return true;
  }).join("\n");
}

// 3) detect host var from first ".get('/ui/" or ".use('/ui/"
const m = s.match(/^\s*([A-Za-z_$][\w$]*)\.(get|use)\(\s*["']\/ui\//m);
const host = m ? m[1] : "app"; // fallback

// 4) replace any broken router.get mount with host.get
s = s.replace(/^\s*router\.get\(\s*["']\/ui\/admin\/provision["']\s*,\s*uiAdminProvision\s*\);\s*$/gm,
              `${host}.get("/ui/admin/provision", uiAdminProvision);`);

// 5) if route missing, insert it after first UI mount line
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
    console.error("FAIL: Could not insert admin provision mount (no UI mount line found).");
    process.exit(2);
  }
  s = lines.join("\n");
}

fs.writeFileSync(file, s, "utf8");
console.log(`OK: routes.ts fixed (host=${host})`);
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ B3.2e applied"
echo "Backup: $BAK"
