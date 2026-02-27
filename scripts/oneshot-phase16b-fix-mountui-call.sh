#!/usr/bin/env bash
set -euo pipefail

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase16b_${ts}"
echo "==> Phase16b OneShot (fix mountUi(app) call) @ $(pwd)"
mkdir -p "$bak"
cp src/server.ts "$bak"/server.ts 2>/dev/null || true
echo "✅ backup -> $bak"

node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const p = path.join(process.cwd(), "src/server.ts");
let s = fs.readFileSync(p, "utf8");

// replace mountUi(app, {...}) -> mountUi(app)
s = s.replace(/mountUi\(\s*app\s+as\s+any\s*,\s*\{[^}]*\}\s*\)\s*;?/g, "mountUi(app as any);");
s = s.replace(/mountUi\(\s*app\s*,\s*\{[^}]*\}\s*\)\s*;?/g, "mountUi(app as any);");

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mountUi(app) only)");
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase16b installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
