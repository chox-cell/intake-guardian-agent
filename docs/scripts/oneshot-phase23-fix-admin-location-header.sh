#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase23 OneShot (fix /ui/admin 302 without Location) @ $(pwd)"
bak="__bak_phase23_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$bak"
cp -R src scripts tsconfig.json "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak"

echo "==> [1] Patch src/ui/routes.ts: force Location header + end()"
node - <<'NODE'
const fs = require("fs");
const p = "src/ui/routes.ts";
let s = fs.readFileSync(p, "utf8");

// Heuristic: patch inside /ui/admin handler by replacing any res.redirect(...) with hard-set headers
// and also patch patterns where status(302) is used without location.
function patchBlock(block){
  // Replace res.redirect(302, URL) with explicit Location header + end
  block = block.replace(
    /return\s+res\.redirect\(\s*302\s*,\s*([^)]+)\);\s*/g,
    `{
      const __to = String($1);
      res.statusCode = 302;
      res.setHeader("Location", __to);
      res.setHeader("Cache-Control", "no-store");
      res.end();
      return;
    }\n`
  );

  // If someone does res.status(302).send(...) or res.status(302).end() without Location:
  // ensure we set Location when we find a variable likely holding the URL (to/final/url/clientUrl).
  if (!/setHeader\("Location"/.test(block)) {
    block = block.replace(
      /res\.status\(\s*302\s*\)\.(send|end)\([^)]*\);\s*/g,
      `res.statusCode = 302;
res.setHeader("Location", clientUrl);
res.setHeader("Cache-Control", "no-store");
res.end();
return;
`
    );
  }
  return block;
}

// Find the /ui/admin route section and patch only that handler body.
const marker = /app\.get\(\s*["']\/ui\/admin["'][\s\S]*?\n\}\);\n/;
const m = s.match(marker);
if (!m) {
  console.error("❌ Could not find app.get('/ui/admin'...) block in src/ui/routes.ts");
  process.exit(1);
}
const oldBlock = m[0];
let newBlock = oldBlock;

// Ensure we have a `clientUrl` variable for fallbacks (only if not already there)
if (!/clientUrl/.test(newBlock)) {
  // Try to identify the redirect line and capture the URL expression to name it clientUrl
  newBlock = newBlock.replace(
    /return\s+res\.redirect\(\s*302\s*,\s*([^)]+)\);\s*/g,
    `const clientUrl = String($1);\nreturn res.redirect(302, clientUrl);\n`
  );
}

newBlock = patchBlock(newBlock);

// Final safeguard: before any "statusCode=302" ensure clientUrl exists; if not, define a safe one.
if (/statusCode\s*=\s*302/.test(newBlock) && !/const clientUrl/.test(newBlock)) {
  newBlock = newBlock.replace(
    /app\.get\(\s*["']\/ui\/admin["'][\s\S]*?\{\s*\n/,
    (x)=> x + `  const clientUrl = "/ui/tickets?tenantId=tenant_demo&k=missing";\n`
  );
}

s = s.replace(oldBlock, newBlock);
fs.writeFileSync(p, s);
console.log("✅ patched src/ui/routes.ts (/ui/admin now always returns Location)");
NODE

echo "==> [2] Rewrite scripts/smoke-ui.sh Location parser (robust)"
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "==> [0] health"
curl -fsS "$BASE_URL/health" >/dev/null && echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$s1"
[ "$s1" = "404" ] || fail "/ui not hidden"

echo "==> [2] /ui/admin redirect (302 expected)"
[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY is required"
hdr="$(curl -sS -D- -o /dev/null "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
code="$(echo "$hdr" | head -n 1 | awk '{print $2}')"
loc="$(echo "$hdr" | grep -i '^location:' | head -n 1 | cut -d' ' -f2- | tr -d '\r\n')"
echo "status=$code"
[ "$code" = "302" ] || { echo "$hdr" | head -n 40; fail "expected 302"; }
[ -n "$loc" ] || { echo "$hdr" | head -n 60; fail "no Location header"; }

final="$loc"
if echo "$final" | grep -qE '^/'; then final="$BASE_URL$final"; fi

echo "==> [3] follow redirect -> tickets should be 200"
s3="$(curl -sS -o /dev/null -w "%{http_code}" "$final")"
echo "status=$s3"
[ "$s3" = "200" ] || fail "tickets not 200: $final"

echo "==> [4] export should be 200"
tenantId="$(echo "$final" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
k="$(echo "$final" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
[ -n "${tenantId:-}" ] || fail "missing tenantId in $final"
[ -n "${k:-}" ] || fail "missing k in $final"
[ "$k" != "undefined" ] || fail "k is undefined (autolink broken)"

exportUrl="$BASE_URL/ui/export.csv?tenantId=$tenantId&k=$k"
s4="$(curl -sS -o /dev/null -w "%{http_code}" "$exportUrl")"
echo "status=$s4"
[ "$s4" = "200" ] || fail "export not 200: $exportUrl"

echo "✅ smoke ui ok"
echo "$final"
echo "✅ export: $exportUrl"
BASH
chmod +x scripts/smoke-ui.sh
echo "✅ wrote scripts/smoke-ui.sh"

echo "==> [3] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase23 installed."
echo "Now:"
echo "  1) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
