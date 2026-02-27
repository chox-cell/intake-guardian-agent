#!/usr/bin/env bash
set -euo pipefail

echo "==> Hotfix Phase2 TS (tenant-key signature + ui_v6 import)"

# 1) Make requireTenantKey backward-compatible (accept 4th arg)
node - <<'NODE'
const fs = require("fs");
const p = "src/api/tenant-key.ts";
let s = fs.readFileSync(p,"utf8");

// replace function signature line safely
s = s.replace(
  /export function requireTenantKey\(\s*req:\s*Request,\s*tenantId:\s*string,\s*tenantsStore\?:\s*TenantsStore\s*\)\s*\{/,
  'export function requireTenantKey(req: Request, tenantId: string, tenantsStore?: TenantsStore, _ignored?: any) {'
);

// if not found (different spacing), do a more flexible replace
if (!s.includes("export function requireTenantKey(req: Request, tenantId: string, tenantsStore?: TenantsStore, _ignored?: any) {")) {
  s = s.replace(
    /export function requireTenantKey\(\s*req:\s*Request,\s*tenantId:\s*string,\s*tenantsStore\?:\s*TenantsStore[^\)]*\)\s*\{/m,
    'export function requireTenantKey(req: Request, tenantId: string, tenantsStore?: TenantsStore, _ignored?: any) {'
  );
}

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE

# 2) Remove bad Store type import from ui_v6 (it’s not exported and not needed)
node - <<'NODE'
const fs = require("fs");
const p = "src/api/ui_v6.ts";
let s = fs.readFileSync(p,"utf8");

// remove the problematic import line if exists
s = s.replace(/^import\s+type\s+\{\s*Store\s*\}\s+from\s+"\.\/routes\.js";[^\n]*\n/m, "");

// also remove any other Store-only type import variants
s = s.replace(/^import\s+type\s+\{\s*Store\s*\}\s+from\s+"\.\/routes";[^\n]*\n/m, "");

fs.writeFileSync(p, s);
console.log("✅ patched", p);
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo "==> Commit (optional)"
git add src/api/tenant-key.ts src/api/ui_v6.ts >/dev/null 2>&1 || true
git commit -m "fix(phase2): TS hotfix (tenant-key accepts legacy 4th arg + ui_v6 import cleanup)" >/dev/null 2>&1 || true

echo
echo "✅ Done."
echo "Now:"
echo "  1) pnpm dev"
echo "  2) BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  3) BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
