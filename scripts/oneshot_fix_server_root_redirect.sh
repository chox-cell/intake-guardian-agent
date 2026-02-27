#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/Projects/intake-guardian-agent"
cd "$REPO"

FILE="src/server.ts"
BAK=".bak/$(date -u +%Y%m%dT%H%M%SZ)_server_root_fix"
mkdir -p "$BAK"
cp "$FILE" "$BAK/server.ts.bak"

node <<'NODE'
const fs = require("fs");

const file = "src/server.ts";
let s = fs.readFileSync(file, "utf8");

if (!s.includes('app.get("/",')) {
  // inject after app initialization
  s = s.replace(
    /(const app\s*=\s*express\(\)\s*;?)/,
    `$1

// UX FIX: root redirect
app.get("/", (_req, res) => {
  res.redirect("/ui/welcome");
});
`
  );
  fs.writeFileSync(file, s, "utf8");
  console.log("PATCH_OK: added GET / redirect");
} else {
  console.log("SKIP: GET / already exists");
}
NODE

echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json --noEmit

echo "OK ✅ server.ts fixed safely"
echo "Backup at $BAK"
