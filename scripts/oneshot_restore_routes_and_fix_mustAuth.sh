#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_restore_routes_mustAuth"
mkdir -p "$BAK"

FILE="src/ui/routes.ts"

echo "==> Selecting best backup candidate for routes.ts..."
# Prefer the easy_mode_fix backup if exists, otherwise newest routes.ts.bak in .bak
CANDIDATE="$(ls -t .bak/*_easy_mode_fix/routes.ts.bak 2>/dev/null | head -n 1 || true)"
if [[ -z "${CANDIDATE}" ]]; then
  CANDIDATE="$(ls -t .bak/*/routes.ts.bak 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${CANDIDATE}" ]]; then
  echo "FAIL: no routes.ts.bak found under .bak/"
  exit 2
fi

echo "==> Using backup: ${CANDIDATE}"
cp -a "$FILE" "$BAK/routes.ts.before_restore"
cp -a "$CANDIDATE" "$FILE"

node <<'NODE'
const fs = require("fs");

const f = "src/ui/routes.ts";
let s = fs.readFileSync(f, "utf8");

// Patch ONLY the mustAuth invalid-key branch.
// Replace the entire if-block content with a clean, valid TS block.
const re = /if\s*$begin:math:text$\!verifyTenantKeyLocal\\\(\\s\*tenantId\\s\*\,\\s\*tenantKey\\s\*$end:math:text$\)\s*\{\s*[\s\S]*?\n\s*\}/m;

const replacement =
`if (!verifyTenantKeyLocal(tenantId, tenantKey)) {
    res.status(401).send(htmlPage("Unauthorized", \`
      <div style="padding:24px">
        <h1 style="margin:0 0 10px 0">Unauthorized</h1>
        <p style="color:#9ca3af;margin:0">Invalid or missing tenant key.</p>
        <p style="color:#9ca3af;margin:6px 0 0">Ask your agency for a fresh invite link.</p>
      </div>
    \`));
    return null;
  }`;

if (!re.test(s)) {
  console.error("FAIL: could not find mustAuth verifyTenantKeyLocal block to patch.");
  process.exit(3);
}

s = s.replace(re, replacement);

// Also ensure there's no stray 'return;' followed by 'return null;' inside mustAuth
// (we want mustAuth to always return null on failure, object on success)
s = s.replace(/\n\s*return;\s*\n\s*return null;\s*\n/g, "\n    return null;\n");

fs.writeFileSync(f, s, "utf8");
console.log("OK: routes.ts restored + mustAuth fixed safely");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo
echo "OK ✅ routes.ts restored + mustAuth fixed"
echo "Backup of previous state: $BAK/routes.ts.before_restore"
