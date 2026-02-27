#!/usr/bin/env bash
set -euo pipefail

echo "==> OneShot Hotfix: server.ts (dedupe makeUiRoutes + allow publicBaseUrl) @ $(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_ui_v6_hotfix_${TS}"
mkdir -p "$BAK" scripts

cp -a src/server.ts "$BAK/server.ts.bak" 2>/dev/null || true

echo "==> [1] Patch src/server.ts"
node <<'NODE'
import fs from "fs";

const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// 1) Remove old ui import (./api/ui.js)
s = s.replace(/^\s*import\s+\{\s*makeUiRoutes\s*\}\s+from\s+["']\.\/api\/ui\.js["']\s*;\s*\n/mg, "");

// 2) Ensure exactly one import from ui_v6
// Remove duplicates first
s = s.replace(/^\s*import\s+\{\s*makeUiRoutes\s*\}\s+from\s+["']\.\/api\/ui_v6\.js["']\s*;\s*\n/mg, "");
// Insert after last import line
const lines = s.split("\n");
let lastImport = -1;
for (let i=0;i<lines.length;i++){
  if (lines[i].startsWith("import ")) lastImport = i;
}
if (lastImport >= 0) {
  lines.splice(lastImport+1, 0, 'import { makeUiRoutes } from "./api/ui_v6.js";');
} else {
  lines.unshift('import { makeUiRoutes } from "./api/ui_v6.js";');
}
s = lines.join("\n");

// 3) Replace any existing /ui mount blocks with a single stable one
// Remove all app.use("/ui", makeUiRoutes(...));
s = s.replace(/^\s*app\.use\(\s*["']\/ui["']\s*,\s*makeUiRoutes\([\s\S]*?\)\s*\)\s*;\s*$/gm, "");

// Insert mount right after `const app = express();`
const marker = /const\s+app\s*=\s*express\(\)\s*;?/;
if (marker.test(s)) {
  s = s.replace(marker, (m) => {
    return m + `

/** UI v6 (All-in-one) */
app.use("/ui", makeUiRoutes({
  store,
  tenants,
  publicBaseUrl: process.env.PUBLIC_BASE_URL,
  demo: {
    whatsappPhone: process.env.WHATSAPP_DEMO_PHONE,
    whatsappText: process.env.WHATSAPP_DEMO_TEXT || "Hi Intake-Guardian, I want a demo.",
    contactEmail: process.env.CONTACT_EMAIL || process.env.RESEND_FROM
  }
} as any));
`;
  });
}

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [2] Typecheck"
pnpm -s lint:types

echo "==> ✅ Hotfix done"
echo "Now run: pnpm dev"
echo "Then: BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
