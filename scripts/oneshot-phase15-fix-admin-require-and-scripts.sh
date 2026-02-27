#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
ts="$(date +%Y%m%d_%H%M%S)"
bak="__bak_phase15_${ts}"

echo "==> Phase15 OneShot (fix ESM require in /ui/admin + bash-only scripts) @ $ROOT"
mkdir -p "$bak"
cp -R src scripts tsconfig.json package.json "$bak"/ 2>/dev/null || true
echo "✅ backup -> $bak"

echo "==> [1] Patch src/ui/routes.ts (remove require() in ESM)"
node <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const p = path.join(process.cwd(), "src/ui/routes.ts");
let s = fs.readFileSync(p, "utf8");

// Ensure crypto import exists (ESM-safe)
if (!s.includes('from "node:crypto"') && !s.includes("from 'node:crypto'")) {
  // insert after first import line (or at top)
  const lines = s.split("\n");
  let idx = lines.findIndex(l => l.startsWith("import "));
  if (idx === -1) idx = 0;
  lines.splice(idx, 0, 'import crypto from "node:crypto";');
  s = lines.join("\n");
}

// Replace any `require("crypto")` / `require("node:crypto")` patterns
s = s.replace(/require\(["']node:crypto["']\)/g, "crypto");
s = s.replace(/require\(["']crypto["']\)/g, "crypto");

// Replace constantTimeEq implementation (most common crash point)
const re = /function\s+constantTimeEq\s*\([\s\S]*?\n}\n/;
if (re.test(s)) {
  s = s.replace(re, `function constantTimeEq(a: any, b: any) {
  const aa = Buffer.from(String(a ?? ""));
  const bb = Buffer.from(String(b ?? ""));
  if (aa.length !== bb.length) return false;
  try {
    return crypto.timingSafeEqual(aa, bb);
  } catch {
    // ultra-safe fallback (shouldn't happen)
    return String(a ?? "") === String(b ?? "");
  }
}
`);
} else {
  // If function not found, inject a safe helper near top (after imports)
  const lines = s.split("\n");
  let insertAt = lines.findIndex(l => l.startsWith("import "));
  while (insertAt !== -1 && insertAt < lines.length && lines[insertAt].startsWith("import ")) insertAt++;
  if (insertAt === -1) insertAt = 0;
  lines.splice(insertAt, 0,
`function constantTimeEq(a: any, b: any) {
  const aa = Buffer.from(String(a ?? ""));
  const bb = Buffer.from(String(b ?? ""));
  if (aa.length !== bb.length) return false;
  try { return crypto.timingSafeEqual(aa, bb); } catch { return String(a ?? "") === String(b ?? ""); }
}
`);
  s = lines.join("\n");
}

// Final guard: hard ban require() in this file
if (s.includes("require(")) {
  // Replace remaining require usage with a visible error marker so we catch it
  s = s.replace(/require\(/g, "/*require_removed*/(");
}

fs.writeFileSync(p, s);
console.log("✅ patched src/ui/routes.ts (ESM-safe, no require)");
NODE

echo "==> [2] Rewrite scripts/demo-keys.sh (bash-only + correct export link)"
cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-dev_admin_key_123}"

admin_url="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"

echo "==> Open admin autolink (will redirect to client UI)"
echo "$admin_url"
echo

# Resolve redirect target (Location header)
loc="$(
  curl -sS -I "$admin_url" \
  | tr -d '\r' \
  | awk 'tolower($1)=="location:"{print $2; exit}'
)"

if [[ -z "${loc:-}" ]]; then
  echo "❌ no redirect location from /ui/admin"
  curl -sS -i "$admin_url" | head -n 60
  exit 1
fi

# If Location is relative, prefix BASE_URL
if [[ "$loc" == /* ]]; then
  final="${BASE_URL}${loc}"
else
  final="$loc"
fi

echo "✅ client link:"
echo "$final"
echo
echo "==> ✅ Export CSV"
echo "${final/\/ui\/tickets/\/ui\/export.csv}"
BASH
chmod +x scripts/demo-keys.sh

echo "==> [3] Rewrite scripts/smoke-ui.sh (bash-only, stable checks)"
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-dev_admin_key_123}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
curl -fsS "${BASE_URL}/health" >/dev/null && echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
code="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/ui" || true)"
echo "status=$code"
[[ "$code" == "404" ]] || fail "expected 404 for /ui"

echo "==> [2] /ui/admin redirect (302 expected)"
admin_url="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"
code="$(curl -sS -o /dev/null -w "%{http_code}" -I "$admin_url" || true)"
echo "status=$code"
[[ "$code" == "302" ]] || {
  echo "---- debug headers ----"
  curl -sS -I "$admin_url" | head -n 40
  echo "---- debug body (first lines) ----"
  curl -sS "$admin_url" | head -n 60
  fail "expected 302 from /ui/admin"
}

loc="$(curl -sS -I "$admin_url" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2; exit}')"
[[ -n "${loc:-}" ]] || fail "no Location"

if [[ "$loc" == /* ]]; then final="${BASE_URL}${loc}"; else final="$loc"; fi

echo "==> [3] follow redirect -> tickets should be 200"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$final" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "expected 200 on tickets: $final"

echo "==> [4] export should be 200"
export_url="${final/\/ui\/tickets/\/ui\/export.csv}"
code="$(curl -sS -o /dev/null -w "%{http_code}" "$export_url" || true)"
echo "status=$code"
[[ "$code" == "200" ]] || fail "expected 200 on export: $export_url"

echo "✅ smoke ui ok"
echo "$final"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase15 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
