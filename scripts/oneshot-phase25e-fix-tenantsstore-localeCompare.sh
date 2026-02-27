#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase25e_${TS}"

echo "==> Phase25e OneShot (fix tenants/store.ts localeCompare crash) @ $ROOT"
mkdir -p "$BAK"
cp -R src tsconfig.json package.json "$BAK/" >/dev/null 2>&1 || true
echo "✅ backup -> $BAK"

# [1] Ensure tsconfig ignores backups (non-breaking)
if [ -f tsconfig.json ]; then
  node <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "__bak_phase*"]));
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE
fi

# [2] Patch src/tenants/store.ts: make localeCompare safe on undefined
FILE="src/tenants/store.ts"
[ -f "$FILE" ] || { echo "❌ missing $FILE"; exit 1; }

node <<'NODE'
const fs = require("fs");

const file = "src/tenants/store.ts";
let s = fs.readFileSync(file, "utf8");

// Generic safe replacement:
// a.foo.localeCompare(b.foo)  -> String(a.foo||"").localeCompare(String(b.foo||""))
const re = /([A-Za-z_$][\w$]*)\.([A-Za-z_$][\w$]*)\.localeCompare\(\s*([A-Za-z_$][\w$]*)\.([A-Za-z_$][\w$]*)\s*\)/g;

let changed = false;
s = s.replace(re, (_m, a, af, b, bf) => {
  changed = true;
  return `String(${a}.${af} ?? "").localeCompare(String(${b}.${bf} ?? ""))`;
});

// Also cover optional chaining variants if present: a?.foo?.localeCompare(b?.foo)
const re2 = /([A-Za-z_$][\w$]*)\?\.\s*([A-Za-z_$][\w$]*)\?\.\s*localeCompare\(\s*([A-Za-z_$][\w$]*)\?\.\s*([A-Za-z_$][\w$]*)\s*\)/g;
s = s.replace(re2, (_m, a, af, b, bf) => {
  changed = true;
  return `String(${a}?.${af} ?? "").localeCompare(String(${b}?.${bf} ?? ""))`;
});

if (!changed) {
  console.log("⚠️ No localeCompare pattern replaced (file may already be safe).");
} else {
  fs.writeFileSync(file, s);
  console.log("✅ patched src/tenants/store.ts (safe localeCompare)");
}
NODE

# [3] Typecheck (best effort)
if pnpm -s lint:types >/dev/null 2>&1; then
  echo "==> Typecheck"
  pnpm -s lint:types
else
  echo "==> Typecheck skipped (no lint:types)."
fi

echo
echo "✅ Phase25e installed."
echo "Now:"
echo "  1) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  3) BASE_URL=http://127.0.0.1:7090 TENANT_ID=tenant_demo ./scripts/smoke-webhook.sh"
