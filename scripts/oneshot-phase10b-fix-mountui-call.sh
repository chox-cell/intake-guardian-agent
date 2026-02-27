#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase10b OneShot (fix mountUi call args) @ $(pwd)"

TS=$(date +"%Y%m%d_%H%M%S")
BAK="__bak_phase10b_${TS}"
mkdir -p "$BAK"
cp -R src "$BAK" 2>/dev/null || true
echo "✅ backup -> $BAK"

echo "==> [1] Patch src/server.ts (remove tenants from mountUi call)"
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
if (!fs.existsSync(p)) throw new Error("missing src/server.ts");
let s = fs.readFileSync(p, "utf8");

const before = s;

// common patterns we saw
s = s.replace(
  /mountUi\(\s*app\s+as\s+any\s*,\s*\{\s*store:\s*store\s+as\s+any\s*,\s*tenants:\s*tenants\s+as\s+any\s*\}\s*\)\s*;/g,
  "mountUi(app as any, { store: store as any });"
);

// fallback: remove `, tenants: ...` inside mountUi call if formatted differently
s = s.replace(
  /mountUi\(([^)]*)\{\s*store:\s*store\s+as\s+any\s*,\s*tenants:\s*tenants\s+as\s+any\s*\}\s*\)/g,
  "mountUi($1{ store: store as any })"
);

if (s === before) {
  console.error("❌ could not find mountUi call to patch. Search for 'mountUi(' in src/server.ts and paste it here.");
  process.exit(2);
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts");
NODE

echo "==> [2] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase10b installed."
echo "Now run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
