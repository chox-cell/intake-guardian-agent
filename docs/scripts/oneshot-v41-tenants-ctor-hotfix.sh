#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
echo "==> OneShot v4.1: TenantsStore ctor hotfix @ $ROOT ($TS)"

if [ ! -f package.json ]; then
  echo "❌ Run this from repo root (package.json not found)."
  exit 1
fi

mkdir -p "__bak_tenants_ctor_${TS}"
cp -a src/server.ts "__bak_tenants_ctor_${TS}/server.ts.bak" || true

echo "==> [1] Patch src/server.ts (TenantsStore expects { dataDir })"
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// Replace common wrong patterns:
// 1) new TenantsStore(path.resolve(DATA_DIR, "tenants.json"))
// 2) new TenantsStore(path.resolve(DATA_DIR, "tenants.json", ...))
// 3) any new TenantsStore(<string_path>)  -> new TenantsStore({ dataDir: path.resolve(DATA_DIR) })
const before = s;

const patterns = [
  /new\s+TenantsStore\(\s*path\.resolve\(\s*DATA_DIR\s*,\s*["']tenants\.json["']\s*\)\s*\)/g,
  /new\s+TenantsStore\(\s*path\.join\(\s*DATA_DIR\s*,\s*["']tenants\.json["']\s*\)\s*\)/g,
  /new\s+TenantsStore\(\s*path\.resolve\(\s*DATA_DIR\s*,[\s\S]*?\)\s*\)/g, // fallback (still turns into dataDir)
  /new\s+TenantsStore\(\s*["'][^"']+tenants\.json["']\s*\)/g
];

let replaced = false;
for (const re of patterns) {
  if (re.test(s)) {
    s = s.replace(re, 'new TenantsStore({ dataDir: path.resolve(DATA_DIR) })');
    replaced = true;
    break;
  }
}

// If not found, try a targeted fix for "tenants = new TenantsStore(..."
if (!replaced) {
  const re2 = /(const\s+tenants\s*=\s*new\s+TenantsStore)\(\s*([^)]+)\s*\)\s*;/;
  if (re2.test(s)) {
    s = s.replace(re2, '$1({ dataDir: path.resolve(DATA_DIR) });');
    replaced = true;
  }
}

if (!replaced) {
  console.error("❌ Could not locate TenantsStore constructor usage to patch.");
  process.exit(1);
}

if (s === before) {
  console.error("❌ Patch produced no change (unexpected).");
  process.exit(1);
}

fs.writeFileSync(p, s);
console.log("✅ Patched", p);
NODE

echo "==> [2] Typecheck"
pnpm -s lint:types

echo "==> [3] Commit"
git add src/server.ts
git commit -m "fix(tenants): pass {dataDir} to TenantsStore ctor" || true

cat <<EOF

✅ v4.1 applied.

Now run:
  pnpm dev

Open UI:
  http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123

Export CSV:
  http://127.0.0.1:7090/ui/export.csv?tenantId=tenant_demo&k=dev_key_123

Quick HTTP check:
  curl -i "http://127.0.0.1:7090/ui/tickets?tenantId=tenant_demo&k=dev_key_123" | head -n 25
EOF
