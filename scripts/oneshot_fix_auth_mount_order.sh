#!/usr/bin/env bash
set -euo pipefail

TS="${TS:-$(date -u +"%Y%m%dT%H%M%SZ")}"
mkdir -p ".bak/$TS"
cp -v src/server.ts ".bak/$TS/server.ts.bak" >/dev/null

node <<'NODE'
const fs = require("fs");

const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// 1) locate auth mount block (Option B)
const re = /\n\s*\/\/ Auth \(Option B\)\n\s*app\.use\("\/api\/auth"[\s\S]*?\)\);\s*\n/gm;
const m = s.match(re);
if (!m || !m[0]) {
  console.error("FAIL: could not find Auth (Option B) mount block in src/server.ts");
  process.exit(2);
}
const block = m[0];

// remove it from original location
s = s.replace(re, "\n");

// 2) find where json middleware is installed
const marker = 'app.use(express.json({ limit: "2mb" }));';
const idx = s.indexOf(marker);
if (idx < 0) {
  console.error('FAIL: could not find marker: ' + marker);
  process.exit(3);
}

// insert auth mount right AFTER express.json(...)
const insertAt = idx + marker.length;
s = s.slice(0, insertAt) + block + s.slice(insertAt);

// 3) sanity: ensure auth mount is now after json
const newIdxAuth = s.indexOf('app.use("/api/auth"');
const newIdxJson = s.indexOf(marker);
if (newIdxAuth < 0 || newIdxJson < 0 || newIdxAuth < newIdxJson) {
  console.error("FAIL: auth mount is not after express.json() after patch");
  process.exit(4);
}

fs.writeFileSync(p, s, "utf8");
console.log("OK: moved /api/auth mount after express.json()");
NODE

echo "==> typecheck"
pnpm -s tsc -p tsconfig.json --noEmit

echo "OK ✅ auth mount order fixed"
echo "Backup: .bak/$TS/server.ts.bak"
