#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts="$(date -u +"%Y%m%dT%H%M%SZ")"
BAK=".bak/${ts}"
mkdir -p "$BAK"

echo "==> One-shot B3.1: Fix TS backticks in src/ui/admin_provision_route.ts"
echo "==> ROOT: $ROOT"
echo "==> BAK : $BAK"
echo

cp -v src/ui/admin_provision_route.ts "$BAK/src_ui_admin_provision_route.ts.bak" >/dev/null

node - <<'NODE'
const fs = require("fs");

const file = "src/ui/admin_provision_route.ts";
let s = fs.readFileSync(file, "utf8");

// Replace the inner template literal `...` used for "block" with safe array join.
// We target the exact region between "const block =" and 'document.getElementById("all").value = block;'
const re = /const block\s*=\s*`[\s\S]*?`;\s*\n\s*document\.getElementById\("all"\)\.value\s*=\s*block;\s*/m;

if (!re.test(s)) {
  console.error("FAIL: Could not find the `const block =` template literal block. The file format changed.");
  process.exit(1);
}

const replacement =
`const block = [
  "Decision Cover — Agency Kit",
  "",
  "Invite (Welcome):",
  json.links.welcome,
  "",
  "Pilot:",
  json.links.pilot,
  "",
  "Tickets:",
  json.links.tickets,
  "",
  "Decisions:",
  json.links.decisions,
  "",
  "Export CSV:",
  json.links.csv,
  "",
  "Evidence ZIP:",
  json.links.zip,
  "",
  "Webhook (Zapier/Form POST):",
  "URL: " + json.webhook.url,
  "Method: POST",
  "Headers:",
  "  content-type: application/json",
  "  x-tenant-key: " + json.webhook.headers["x-tenant-key"],
  "",
  "Body example:",
  JSON.stringify(json.webhook.bodyExample, null, 2),
  "",
  "Quick test (curl):",
  json.curl,
  ""
].join("\\n");
document.getElementById("all").value = block;
`;

s = s.replace(re, replacement);

fs.writeFileSync(file, s, "utf8");
console.log("OK: Patched admin_provision_route.ts (removed nested backticks)");
NODE

echo
echo "==> typecheck"
pnpm -s typecheck || pnpm -s tsc -p tsconfig.json

echo
echo "OK ✅ B3.1 applied"
echo "Backup: $BAK"
