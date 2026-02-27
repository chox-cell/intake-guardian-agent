#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts(){ date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase21e_$(ts)"
echo "==> Phase21e OneShot (fix admin.ts args + remove rogue app.get in ui/routes.ts) @ $ROOT"
mkdir -p "$BAK"
cp -R src "$BAK/src" 2>/dev/null || true
cp -R scripts "$BAK/scripts" 2>/dev/null || true
echo "✅ backup -> $BAK"

# 1) Patch src/api/admin.ts to pass dataDir
node - <<'NODE'
const fs = require("fs");
const p = "src/api/admin.ts";
let s = fs.readFileSync(p, "utf8");

// ensure DATA_DIR local var exists; if not, insert
if (!s.includes("const DATA_DIR")) {
  s = s.replace(/export function mountAdmin\([\s\S]*?\{\n/, (m)=> m + `  const DATA_DIR = process.env.DATA_DIR || "./data";\n`);
}

// patch getTenant(tenantId) -> getTenant(DATA_DIR, tenantId)
s = s.replace(/\bgetTenant\(\s*tenantId\s*\)/g, "getTenant(DATA_DIR, tenantId)");

// patch rotateTenantKey(tenantId) -> rotateTenantKey(DATA_DIR, tenantId)
s = s.replace(/\brotateTenantKey\(\s*tenantId\s*\)/g, "rotateTenantKey(DATA_DIR, tenantId)");

// patch listTenants(...) calls to listTenants(DATA_DIR) if exist
s = s.replace(/\blistTenants\(\s*process\.env\.DATA_DIR\s*\|\|\s*"\.\/data"\s*\)/g, "listTenants(DATA_DIR)");

// patch createTenant(process.env.DATA_DIR || "./data", notes) -> createTenant(DATA_DIR, notes)
s = s.replace(/\bcreateTenant\(\s*process\.env\.DATA_DIR\s*\|\|\s*"\.\/data"\s*,\s*notes\s*\)/g, "createTenant(DATA_DIR, notes)");

fs.writeFileSync(p, s);
console.log("✅ patched src/api/admin.ts (DATA_DIR + correct function args)");
NODE

# 2) Remove rogue app.get("/ui/admin"... outside mountUi
node - <<'NODE'
const fs = require("fs");
const p = "src/ui/routes.ts";
let s = fs.readFileSync(p, "utf8");

// If there's a rogue block starting with '\napp.get("/ui/admin"' remove it entirely.
const idx = s.indexOf('\napp.get("/ui/admin"');
if (idx !== -1) {
  // remove from idx to end of that handler block (best-effort by counting braces)
  let i = idx + 1;
  let depth = 0;
  let started = false;
  for (; i < s.length; i++) {
    const ch = s[i];
    if (ch === "{") { depth++; started = true; }
    if (ch === "}") { depth--; }
    if (started && depth <= 0) {
      // move forward until we hit ');' end of app.get(...)
      const end = s.indexOf(");", i);
      if (end !== -1) {
        const cutEnd = end + 2;
        s = s.slice(0, idx) + "\n\n// (phase21e) removed rogue app.get('/ui/admin') injected outside mountUi\n" + s.slice(cutEnd);
      }
      break;
    }
  }
  console.log("✅ removed rogue app.get('/ui/admin') outside mountUi");
} else {
  console.log("ℹ️ no rogue app.get('/ui/admin') found");
}

// Additionally: if TypeScript complains about implicit any in mountUi handlers, keep existing file as-is.
// (Your file already has proper mountUi; we only removed the rogue tail.)
fs.writeFileSync(p, s);
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase21e installed."
echo "Now:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
