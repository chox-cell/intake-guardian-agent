#!/usr/bin/env bash
set -euo pipefail
ROOT="$(pwd)"
BAK=".bak/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BAK"
echo "==> One-shot: Fix admin provision 401 (accept adminKey from body/header/query)"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"

cp -a src/server.ts "$BAK/server.ts.bak"

node <<'NODE'
const fs = require("fs");

const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

// Find the /api/admin/provision handler block and make adminKey extraction robust.
// This patch is intentionally defensive: it does not assume exact formatting.
const re = /(app\.post\(\s*["']\/api\/admin\/provision["'][\s\S]*?\{)([\s\S]*?)(\n\}\);)/m;
const m = s.match(re);
if (!m) {
  console.error("FAIL: Could not locate app.post('/api/admin/provision'...) block in src/server.ts");
  process.exit(2);
}

let block = m[0];

// Ensure we compute providedKey from multiple sources (query, header, body)
if (!block.includes("providedKey")) {
  block = block.replace(
    /\{[\s\S]*?\n/,
    match => match + `
  // Accept admin key from query/header/body (dev-friendly, still compared to ADMIN_KEY)
  const providedKey =
    (req.query && (req.query.adminKey || req.query.key)) ||
    req.header("x-admin-key") ||
    req.header("x-admin") ||
    (req.body && (req.body.adminKey || req.body.key)) ||
    "";
`
  );
}

// Replace any existing direct comparisons with ADMIN_KEY to use providedKey.
// We look for patterns like: if (adminKey !== process.env.ADMIN_KEY) ...
block = block.replace(/(const\s+adminKey\s*=\s*[^;]+;)/g, "const adminKey = providedKey;");

// If there is a check that uses req.body.adminKey directly, normalize it:
block = block.replace(/req\.body\.adminKey/g, "providedKey");

// Ensure there is an auth check; if none, add one (safe default).
if (!/process\.env\.ADMIN_KEY/.test(block)) {
  block = block.replace(
    /\n\s*(\/\/.*\n)*\s*\/\/ Accept admin key[\s\S]*?\n/,
    (mm) => mm + `  const expected = process.env.ADMIN_KEY || "";
  if (!expected || String(providedKey) !== String(expected)) {
    return res.status(401).json({ ok: false, error: "unauthorized" });
  }
`
  );
} else {
  // If expected exists but check is too strict or uses a different var, enforce a single consistent check
  block = block.replace(/if\s*\([\s\S]*?\)\s*\{\s*return\s+res\.status\(401\)[\s\S]*?\}\s*/m, "");
  block = block.replace(
    /(\n\s*\/\/ Accept admin key[\s\S]*?\n)/,
    `$1  const expected = process.env.ADMIN_KEY || "";
  if (!expected || String(providedKey) !== String(expected)) {
    return res.status(401).json({ ok: false, error: "unauthorized" });
  }
`
  );
}

s = s.replace(re, block);
fs.writeFileSync(file, s, "utf8");
console.log("OK: patched src/server.ts (admin key accepted from query/header/body; consistent 401 check)");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ Patch applied"
echo "Backup: $BAK"
echo
echo "NEXT:"
echo "  1) Restart:"
echo "     bash scripts/dev_7090.sh"
echo
echo "  2) Test:"
echo "     curl -i -X POST http://127.0.0.1:7090/api/admin/provision \\"
echo "       -H 'content-type: application/json' \\"
echo "       -d '{\"adminKey\":\"dev_admin_key_123\",\"tenantName\":\"salam\",\"email\":\"choxmou@gmail.com\"}' | head"
