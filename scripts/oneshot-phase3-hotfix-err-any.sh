#!/usr/bin/env bash
set -euo pipefail

echo "==> Hotfix: TS catch(e) unknown -> err:any (routes/adapters/ui)"

ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_hotfix_err_any_${ts}"
mkdir -p "$bak"
cp -a src "$bak/src" 2>/dev/null || true

node <<'NODE'
const fs = require("fs");

const files = [
  "src/api/routes.ts",
  "src/api/adapters.ts",
  "src/api/ui.ts",
];

function patch(p){
  if(!fs.existsSync(p)) return;
  let s = fs.readFileSync(p,"utf8");

  // Insert "const err = e as any;" as first line inside each catch (e) { ... }
  // and replace (e && e.status) -> (err?.status) and (e && e.message) -> (err?.message)
  s = s.replace(/catch\s*\(\s*e\s*\)\s*\{\s*\n/g, (m)=> m + `  const err = e as any;\n`);

  s = s.replace(/\(e\s*&&\s*e\.status\)/g, `(err?.status)`);
  s = s.replace(/\(e\s*&&\s*e\.message\)/g, `(err?.message)`);

  // Also replace any remaining e.status / e.message inside those return lines (safety)
  s = s.replace(/e\.status/g, `err?.status`);
  s = s.replace(/e\.message/g, `err?.message`);

  fs.writeFileSync(p,s);
  console.log("✅ patched", p);
}

files.forEach(patch);
NODE

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ OK. Now:"
echo "  pnpm dev"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
