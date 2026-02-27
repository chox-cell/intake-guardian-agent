#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase6e_${ts}"
mkdir -p "$bak"
cp -R src "$bak/src" 2>/dev/null || true

echo "==> Phase6e Hotfix (mountUi name + correct mount order) @ $ROOT"
echo "==> [0] Backup -> $bak"

SERVER="src/server.ts"

echo "==> [1] Normalize import name to mountUi"
# replace any mountUI import with mountUi, keep .js extension style
perl -0777 -i -pe '
  s/import\s*\{\s*mountUI\s*\}\s*from\s*["'\'']\.\/ui\/routes\.js["'\''];/import { mountUi } from ".\/ui\/routes.js";/g;
  s/import\s*\{\s*mountUI\s*\}\s*from\s*["'\'']\.\/ui\/routes["'\''];/import { mountUi } from ".\/ui\/routes";/g;
  s/\bmountUI\b/mountUi/g;
' "$SERVER"

echo "==> [2] Remove any early mountUi(...) injected before store/tenants"
# remove lines like: mountUi(app as any, { store: store as any, tenants: tenants as any });
perl -i -ne '
  next if $_ =~ /^\s*mountUi\s*\(\s*app.*\)\s*;\s*$/;
  print;
' "$SERVER"

echo "==> [3] Insert mountUi AFTER store+tenants exist, before app.listen"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// ensure we have import
if (!s.includes('from "./ui/routes.js"') && !s.includes('from "./ui/routes"')) {
  // insert after first imports block (best effort)
  const m = s.match(/(\n)(const|async|function)\s+/);
  const idx = m ? m.index : 0;
  s = s.slice(0, idx) + 'import { mountUi } from "./ui/routes.js";\n' + s.slice(idx);
}

// Find app.listen call to inject before it
const listenIdx = s.search(/\bapp\.listen\s*\(/);
if (listenIdx === -1) {
  console.error("❌ Could not find app.listen(...) in src/server.ts");
  process.exit(1);
}

// Only inject if not already present
if (!s.includes("mountUi(app")) {
  const inject = `
  // UI (Phase6e) — mount after store+tenants exist
  mountUi(app as any, { store: store as any, tenants: tenants as any });

`;
  s = s.slice(0, listenIdx) + inject + s.slice(listenIdx);
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUi placed before app.listen)");
NODE

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase6e OK."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
