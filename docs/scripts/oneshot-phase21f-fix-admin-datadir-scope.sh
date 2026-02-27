#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts(){ date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase21f_$(ts)"
echo "==> Phase21f OneShot (fix DATA_DIR scope in src/api/admin.ts) @ $ROOT"
mkdir -p "$BAK"
cp -R src "$BAK/src" 2>/dev/null || true
echo "✅ backup -> $BAK"

node - <<'NODE'
const fs = require("fs");
const p = "src/api/admin.ts";
let s = fs.readFileSync(p, "utf8");

// If DATA_DIR already defined at top-level, do nothing.
if (!/const\s+DATA_DIR\s*=/.test(s)) {
  // Insert after imports (best-effort): after the last import line.
  const lines = s.split("\n");
  let lastImport = -1;
  for (let i=0;i<lines.length;i++){
    if (lines[i].startsWith("import ")) lastImport = i;
  }
  const insertAt = lastImport >= 0 ? lastImport+1 : 0;
  lines.splice(insertAt, 0, '', 'const DATA_DIR = process.env.DATA_DIR || "./data";', '');
  s = lines.join("\n");
}

// Ensure calls use DATA_DIR (already patched in phase21e, but keep safe)
s = s.replace(/\bgetTenant\(\s*tenantId\s*\)/g, "getTenant(DATA_DIR, tenantId)");
s = s.replace(/\brotateTenantKey\(\s*tenantId\s*\)/g, "rotateTenantKey(DATA_DIR, tenantId)");
s = s.replace(/\blistTenants\(\s*process\.env\.DATA_DIR\s*\|\|\s*"\.\/data"\s*\)/g, "listTenants(DATA_DIR)");
s = s.replace(/\bcreateTenant\(\s*process\.env\.DATA_DIR\s*\|\|\s*"\.\/data"\s*,\s*notes\s*\)/g, "createTenant(DATA_DIR, notes)");

fs.writeFileSync(p, s);
console.log("✅ patched src/api/admin.ts (top-level DATA_DIR)");
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase21f installed."
echo "Now:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
