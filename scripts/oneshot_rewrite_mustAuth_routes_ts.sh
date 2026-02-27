#!/usr/bin/env bash
set -euo pipefail

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_rewrite_mustAuth"
mkdir -p "$BAK"

FILE="src/ui/routes.ts"
cp -a "$FILE" "$BAK/routes.ts.bak"

node <<'NODE'
const fs = require("fs");

const file = "src/ui/routes.ts";
let s = fs.readFileSync(file, "utf8");

// Find function mustAuth(...) { ... } and replace it entirely.
// This avoids fragile line-based fixes and fixes your current parse error.
const re = /function\s+mustAuth\s*\(\s*req:\s*any\s*,\s*res:\s*any\s*\)\s*\{\s*[\s\S]*?\n\}/m;

const clean =
`function mustAuth(req: any, res: any) {
  const { tenantId, tenantKey } = getTenantFromReq(req);

  if (!tenantId || !tenantKey) {
    bad(res, "missing tenantId/k", "Use: /ui/tickets?tenantId=...&k=...");
    return null;
  }

  if (!verifyTenantKeyLocal(tenantId, tenantKey)) {
    res
      .status(401)
      .type("html")
      .send(
        htmlPage(
          "Unauthorized",
          \`
          <div style="padding:24px">
            <h1 style="margin:0 0 10px 0">Unauthorized</h1>
            <p style="color:#9ca3af;margin:0">Invalid or missing tenant key.</p>
            <p style="color:#9ca3af;margin:6px 0 0">Ask your agency for a fresh invite link.</p>
          </div>
          \`
        )
      );
    return null;
  }

  return { tenantId, tenantKey };
}`;

if (!re.test(s)) {
  console.error("FAIL: could not locate function mustAuth(req: any, res: any) in routes.ts");
  process.exit(2);
}

s = s.replace(re, clean);

// extra safety: remove any accidental stray 'return;' inside mustAuth area if exists
s = s.replace(/return;\s*\n\s*return null;/g, "return null;");

fs.writeFileSync(file, s, "utf8");
console.log("OK: rewrote mustAuth() cleanly");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ mustAuth fixed"
echo "Backup: $BAK/routes.ts.bak"
