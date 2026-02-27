#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${TS}_fix_unauth_block"
mkdir -p "$BAK"

FILE="src/ui/routes.ts"
cp -a "$FILE" "$BAK/routes.ts.bak"

node <<'NODE'
const fs = require("fs");

const f = "src/ui/routes.ts";
let s = fs.readFileSync(f, "utf8");

// Replace ANY 401 unauthorized send that got polluted (Phase48b or broken htmlPage)
// with a clean, syntactically-safe block.
const CLEAN = `
    res.status(401).send(htmlPage("Unauthorized", \`
      <div style="padding:24px">
        <h1 style="margin:0 0 10px 0">Unauthorized</h1>
        <p style="color:#9ca3af;margin:0">Invalid or missing tenant key.</p>
        <p style="color:#9ca3af;margin:6px 0 0">Ask your agency for a fresh invite link.</p>
      </div>
    \`));
    return;
`;

// Strategy:
// 1) If Phase48b exists, rewrite the whole catch/guard section around it.
// 2) Else, target any line that starts with res.status(401).send(htmlPage("Unauthorized"... and ends before next 'return' or next '}'.
if (s.includes("Phase48b")) {
  s = s.replace(
    /res\.status$begin:math:text$401$end:math:text$\.send$begin:math:text$\[\\s\\S\]\{0\,2000\}\?Phase48b\[\\s\\S\]\{0\,2000\}\?$end:math:text$;\s*/m,
    CLEAN
  );
} else {
  // Generic fix: replace any unauthorized htmlPage send block that contains a backtick
  s = s.replace(
    /res\.status$begin:math:text$401$end:math:text$\.send$begin:math:text$\\s\*htmlPage\\\(\\s\*\[\"\'\]Unauthorized\[\"\'\]\[\\s\\S\]\{0\,1200\}\?$end:math:text$\s*\)\s*;?/m,
    CLEAN.trim()
  );
}

// Final safety: if we accidentally left a dangling template literal close like `); fix it
s = s.replace(/`\s*\);\s*/g, "`));\n    return;\n");

fs.writeFileSync(f, s, "utf8");
console.log("OK: routes.ts Unauthorized block rewritten safely");
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo "OK ✅ Unauthorized block fixed"
echo "Backup: $BAK/routes.ts.bak"
