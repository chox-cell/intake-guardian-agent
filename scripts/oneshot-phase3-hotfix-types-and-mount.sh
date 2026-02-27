#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
echo "==> Phase3 Hotfix (types + /ui mount order) @ $ROOT"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase3_hotfix_${ts}"
mkdir -p "$bak"

echo "==> [0] Backup"
cp -a src "$bak/src" 2>/dev/null || true

echo "==> [1] Patch: replace tk.ok pattern in src/api/routes.ts, src/api/adapters.ts, src/api/ui.ts"
node <<'NODE'
const fs = require("fs");

const files = [
  "src/api/routes.ts",
  "src/api/adapters.ts",
  "src/api/ui.ts",
];

function patchFile(p) {
  if (!fs.existsSync(p)) return;

  let s = fs.readFileSync(p, "utf8");

  // Pattern: const tk = requireTenantKey(...); if (!tk.ok) return ...
  // Replace with try/catch using the throwing gate.
  //
  // We keep the original requireTenantKey(...) call so it still validates the same way,
  // but we no longer expect tk.ok/status/error.
  const re = /(\s*)const\s+tk\s*=\s*requireTenantKey\(([^)]*)\);\s*\n\1if\s*\(!tk\.ok\)\s*return\s*([^\n;]+);?\s*\n/g;

  if (!re.test(s)) {
    // Some files may not match exact formatting; still okay.
    fs.writeFileSync(p, s);
    return;
  }

  s = s.replace(re, (m, indent, args, retExpr) => {
    // Decide HTML vs JSON error response based on file name and return expression
    const isUi = p.includes("/ui.ts");
    const isJson = !isUi; // routes/adapters -> json
    const errBody = isUi
      ? `${indent}  return res.status((e && e.status) || 401).send(\`<pre>\${esc((e && e.message) || "invalid_tenant_key")}</pre>\`);\n`
      : `${indent}  return res.status((e && e.status) || 401).json({ ok: false, error: (e && e.message) || "invalid_tenant_key" });\n`;

    return (
`${indent}try {\n` +
`${indent}  requireTenantKey(${args});\n` +
`${indent}} catch (e) {\n` +
errBody +
`${indent}}\n`
    );
  });

  fs.writeFileSync(p, s);
  console.log("✅ patched", p);
}

for (const f of files) patchFile(f);
NODE

echo "==> [2] Patch: fix /ui mount order in src/server.ts (remove early mounts + insert after tenants/store/app exist)"
node <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
if (!fs.existsSync(p)) {
  console.error("❌ src/server.ts not found");
  process.exit(1);
}
let s = fs.readFileSync(p, "utf8");

// 1) Remove any /ui mounts anywhere (we'll re-add safely)
s = s.replace(/^\s*app\.use\(\s*["']\/ui["']\s*,\s*makeUiRoutes\([^\)]*\)\s*\)\s*;?\s*$/gm, "");

// 2) Ensure import exists exactly once for ui_sell
// remove any old ui imports to avoid duplicates
s = s.replace(/^\s*import\s+\{\s*makeUiRoutes\s*\}\s+from\s+["']\.\/api\/ui(_sell|_v6|)?\.js["'];\s*$/gm, "");
// add ui_sell import after first import block
if (!s.includes(`from "./api/ui_sell.js"`)) {
  const m = s.match(/^(?:import[^\n]*\n)+/);
  if (m) s = s.replace(m[0], m[0] + `import { makeUiRoutes } from "./api/ui_sell.js";\n`);
  else s = `import { makeUiRoutes } from "./api/ui_sell.js";\n` + s;
}

// 3) Insert mount after BOTH tenants + store exist and after app exists.
// We'll look for the line that declares tenants, and insert after it IF app/store exist above.
// Safer: insert after the last of these declarations found:
//   const app = express(...)
//   const store = ...
//   const tenants = new TenantsStore(...)
const lines = s.split("\n");

function findLastIndex(rx) {
  let idx = -1;
  for (let i=0;i<lines.length;i++) if (rx.test(lines[i])) idx = i;
  return idx;
}

const idxApp = findLastIndex(/const\s+app\s*=\s*express\(/);
const idxStore = findLastIndex(/const\s+store\s*=/);
const idxTenants = findLastIndex(/const\s+tenants\s*=\s*new\s+TenantsStore\(/);

let insertAt = Math.max(idxApp, idxStore, idxTenants);
if (insertAt < 0) {
  // fallback: after imports
  insertAt = findLastIndex(/^import\s+/);
}

const mount = `app.use("/ui", makeUiRoutes({ store, tenants }));`;
lines.splice(insertAt + 1, 0, mount);

s = lines.join("\n");

// Cleanup multiple blank lines
s = s.replace(/\n{3,}/g, "\n\n");

fs.writeFileSync(p, s);
console.log("✅ patched", p, `(mounted /ui after line ${insertAt+1})`);
NODE

echo "==> [3] Typecheck"
pnpm -s lint:types

echo
echo "✅ Hotfix applied."
echo "Now run:"
echo "  pnpm dev"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
