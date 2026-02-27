#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase14c_${ts}"
echo "==> Phase14c OneShot (verifyTenantKeyLocal compat 1-arg/2-arg) @ $ROOT"
mkdir -p "$bak"
cp -R src "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak"

echo "==> [1] Patch src/lib/tenant_registry.ts (compat overload)"
node <<'NODE'
const fs = require("fs");
const path = "src/lib/tenant_registry.ts";
let s = fs.readFileSync(path, "utf8");

const start = s.indexOf("export function verifyTenantKeyLocal");
if (start === -1) {
  throw new Error("verifyTenantKeyLocal not found in src/lib/tenant_registry.ts");
}

// remove old function body (best-effort): from export function verifyTenantKeyLocal ... to matching closing brace
// We'll replace the whole function with a compat version.
const before = s.slice(0, start);
const after = s.slice(start);

// find end of function by locating the first occurrence of "\n}\n" after start (works for this simple helper)
let endIdx = after.indexOf("\n}\n");
if (endIdx === -1) endIdx = after.indexOf("\n}\r\n");
if (endIdx === -1) throw new Error("could not locate end of verifyTenantKeyLocal function");
endIdx += 3; // include "\n}\n"
const rest = after.slice(endIdx);

const compatFn = `
/**
 * Compatibility export expected by src/api/tenant-key.ts in this repo.
 * Supports BOTH:
 *  - verifyTenantKeyLocal({ dataDir, tenantId, tenantKey })
 *  - verifyTenantKeyLocal(tenantId, tenantKey)
 */
export function verifyTenantKeyLocal(
  a: { dataDir: string; tenantId: string; tenantKey: string } | string,
  b?: string
): boolean {
  try {
    const p = require("node:path");
    const fs = require("node:fs");
    const dataDir = typeof a === "string" ? process.env.DATA_DIR || "data" : a.dataDir;
    const tenantId = typeof a === "string" ? a : a.tenantId;
    const tenantKey = typeof a === "string" ? (b || "") : a.tenantKey;

    if (!tenantId || !tenantKey) return false;

    const keysPath = p.join(dataDir, "tenant_keys.json");
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

fs.writeFileSync(path, before + compatFn + rest);
console.log("✅ wrote compat verifyTenantKeyLocal()");
NODE

echo "==> [2] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase14c installed."
echo "Now:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
