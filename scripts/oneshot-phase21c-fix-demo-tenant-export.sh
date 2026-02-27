#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts() { date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase21c_$(ts)"
echo "==> Phase21c OneShot (export getOrCreateDemoTenant) @ $ROOT"
mkdir -p "$BAK"
cp -R src "$BAK/src" 2>/dev/null || true
cp tsconfig.json "$BAK/tsconfig.json" 2>/dev/null || true
echo "✅ backup -> $BAK"

# Patch src/lib/tenant_registry.ts: add getOrCreateDemoTenant export if missing
node - <<'NODE'
const fs = require("fs");
const p = "src/lib/tenant_registry.ts";
let s = fs.readFileSync(p, "utf8");

if (s.includes("export async function getOrCreateDemoTenant")) {
  console.log("✅ already has getOrCreateDemoTenant");
  process.exit(0);
}

// Insert helper near bottom (before EOF)
const insert = `

/**
 * Stable demo tenant: always the same tenantId/key.
 * Used by /ui/admin autolink to avoid creating endless tenants.
 */
export async function getOrCreateDemoTenant(dataDir: string = (process.env.DATA_DIR || "./data")): Promise<TenantRecord> {
  const DEMO_ID = "tenant_demo";
  const tenants = await listTenants(dataDir);
  const found = tenants.find(t => t.tenantId === DEMO_ID);
  if (found) return found;

  // create once
  const t = await createTenant(dataDir, "demo (autolink)");
  // force stable id by rewriting record
  const updated = (await listTenants(dataDir)).map(x => {
    if (x.tenantId === t.tenantId) {
      return { ...x, tenantId: DEMO_ID, updatedAtUtc: new Date().toISOString(), notes: "demo (autolink)" };
    }
    return x;
  });

  // write back (we rely on internal file format; safest: reuse private save via overwrite)
  // We don't have direct saveTenants export, so we patch by writing tenants.json directly.
  const path = require("node:path");
  const fp = path.join(dataDir, "tenants.json");
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(fp, JSON.stringify(updated, null, 2) + "\\n");

  const final = updated.find(x => x.tenantId === DEMO_ID);
  if (!final) throw new Error("demo_tenant_create_failed");
  return final;
}
`;

fs.writeFileSync(p, s + insert);
console.log("✅ patched src/lib/tenant_registry.ts (added getOrCreateDemoTenant)");
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase21c installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
