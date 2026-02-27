#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BAK=".bak/$TS"
mkdir -p "$BAK"
cp -f src/server.ts "$BAK/server.ts.bak"

node <<'NODE'
const fs = require("fs");
const path = "src/server.ts";
let s = fs.readFileSync(path, "utf8");

// 1) Add small helper to read provided admin key from query/header/body
if (!s.includes("function __readAdminKey")) {
  s = s.replace(
    /(import .*?\n)/,
    `$1\nimport crypto from "node:crypto";\n`
  );

  const helper = `
function __hash8(v: string) {
  return crypto.createHash("sha256").update(String(v || "")).digest("hex").slice(0, 8);
}
function __readAdminKey(req: any) {
  return (
    (req?.query && (req.query.adminKey || req.query.key)) ||
    req?.header?.("x-admin-key") ||
    req?.header?.("x-admin") ||
    (req?.body && (req.body.adminKey || req.body.key)) ||
    ""
  );
}
`.trim() + "\n\n";

  // Insert helper after first occurrence of express app init OR near top (safe fallback)
  const idx = s.indexOf("const app");
  if (idx !== -1) s = s.slice(0, idx) + helper + s.slice(idx);
  else s = helper + s;
}

// 2) Add safe debug endpoint to show expected admin key hash8 (NOT the key)
if (!s.includes('/api/admin/_keyhash')) {
  // Try to mount after app creation
  const m = s.match(/(app\.use\(|app\.get\(|app\.post\()/);
  const insertAt = m ? s.indexOf(m[0]) : s.length;

  const endpoint = `
/**
 * Debug (SAFE): show hash8 of expected ADMIN_KEY only.
 * Does NOT reveal the key. Helps diagnose 401 mismatches.
 */
app.get("/api/admin/_keyhash", (req, res) => {
  const expected = process.env.ADMIN_KEY || "";
  return res.json({ ok: true, expected_configured: !!expected, expected_hash8: __hash8(expected) });
});
`.trim() + "\n\n";

  s = s.slice(0, insertAt) + endpoint + s.slice(insertAt);
}

// 3) Ensure /api/admin/provision checks key from req body/query/header consistently
// We do a conservative replace: if there is a check "process.env.ADMIN_KEY" and "unauthorized", we wrap it.
if (!s.includes("__readAdminKey(req)")) {
  // Replace common pattern: const expected = process.env.ADMIN_KEY ... if (...) unauthorized
  // We'll insert a tiny guard near the /api/admin/provision handler if found.
  const needle = "/api/admin/provision";
  const p = s.indexOf(needle);
  if (p !== -1) {
    // find next 4000 chars block
    const block = s.slice(p, p + 4000);
    // naive insertion before first unauthorized response inside this block
    const u = block.indexOf("unauthorized");
    if (u !== -1) {
      const abs = p + u;
      // insert expected/provided lines a bit before "unauthorized" token
      const ins = `
  const expected = process.env.ADMIN_KEY || "";
  const provided = __readAdminKey(req);
  if (!expected || String(provided) !== String(expected)) {
    return res.status(401).json({ ok: false, error: "unauthorized" });
  }
`.trim() + "\n\n";
      // Insert before the line containing "unauthorized"
      const lineStart = s.lastIndexOf("\n", abs);
      s = s.slice(0, lineStart + 1) + ins + s.slice(lineStart + 1);
    }
  }
}

fs.writeFileSync(path, s, "utf8");
console.log("OK: patched src/server.ts (safe keyhash endpoint + consistent admin key reading)");
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo "OK ✅ applied"
echo "Backup: $BAK/server.ts.bak"
echo
echo "NEXT:"
echo "  1) Restart server with ADMIN_KEY you want:"
echo "     kill -9 \$(lsof -t -iTCP:7090 -sTCP:LISTEN) 2>/dev/null || true"
echo "     ADMIN_KEY='dev_admin_key_123' bash scripts/dev_7090.sh"
echo
echo "  2) Check expected hash (safe):"
echo "     curl -s http://127.0.0.1:7090/api/admin/_keyhash"
echo
echo "  3) Retry provision:"
echo "     curl -i -X POST http://127.0.0.1:7090/api/admin/provision -H 'content-type: application/json' -d '{\"adminKey\":\"dev_admin_key_123\",\"workspaceName\":\"salam\",\"agencyEmail\":\"test+agency@local.dev\"}' | head"
