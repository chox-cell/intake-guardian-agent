#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase14b_${ts}"
echo "==> Phase14b OneShot (fix verifyTenantKeyLocal export + bash-only demo-keys) @ $ROOT"
mkdir -p "$bak"
cp -R src scripts "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak"

echo "==> [1] Patch src/lib/tenant_registry.ts to export verifyTenantKeyLocal"
node <<'NODE'
const fs = require("fs");
const p = "src/lib/tenant_registry.ts";
let s = fs.readFileSync(p, "utf8");

// If already exists, skip
if (s.includes("export function verifyTenantKeyLocal")) {
  console.log("ℹ️ verifyTenantKeyLocal already present");
  process.exit(0);
}

// Append a compatibility export at end of file
s += `

/**
 * Compatibility export expected by src/api/tenant-key.ts in this repo.
 * Reads data/tenant_keys.json and validates tenantKey for tenantId.
 */
export function verifyTenantKeyLocal(args: { dataDir: string; tenantId: string; tenantKey: string }): boolean {
  const { dataDir, tenantId, tenantKey } = args;
  try {
    const keysPath = require("node:path").join(dataDir, "tenant_keys.json");
    const fs = require("node:fs");
    if (!fs.existsSync(keysPath)) return false;
    const raw = fs.readFileSync(keysPath, "utf8");
    if (!raw || !raw.trim()) return false;
    const j = JSON.parse(raw);
    const rec = j?.tenants?.[tenantId];
    if (!rec) return false;
    return rec.tenantKey === tenantKey;
  } catch {
    return false;
  }
}
`;
fs.writeFileSync(p, s);
console.log("✅ patched tenant_registry.ts (export verifyTenantKeyLocal)");
NODE

echo "==> [2] Make scripts/demo-keys.sh bash-only (no python)"
cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

if [[ -z "$ADMIN_KEY" ]]; then
  echo "ERROR: ADMIN_KEY missing. Example:"
  echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/demo-keys.sh"
  exit 1
fi

adminUrl="$BASE_URL/ui/admin?admin=$ADMIN_KEY"
final="$(curl -s -o /dev/null -w '%{url_effective}' -L "$adminUrl")"

echo "==> ✅ UI link"
echo "$final"
echo
echo "==> ✅ Export CSV"
echo "${final/\/ui\/tickets/\/ui\/export.csv}"
BASH
chmod +x scripts/demo-keys.sh

echo "==> [3] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase14b installed."
echo "Now run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
