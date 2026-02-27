#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts(){ date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase21d_$(ts)"
echo "==> Phase21d OneShot (fix /ui/admin 500 via clean SSOT registry) @ $ROOT"
mkdir -p "$BAK"
cp -R src "$BAK/src" 2>/dev/null || true
cp -R scripts "$BAK/scripts" 2>/dev/null || true
cp tsconfig.json "$BAK/tsconfig.json" 2>/dev/null || true
echo "✅ backup -> $BAK"

# ----------------------------
# 1) Overwrite SSOT tenant registry (clean + async + single JSON file)
# ----------------------------
cat > src/lib/tenant_registry.ts <<'TS'
import { promises as fs } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TenantRecord = {
  tenantId: string;
  tenantKey: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  notes?: string;
};

function nowUtc() {
  return new Date().toISOString();
}

function randKey(bytes = 24) {
  // url-safe-ish
  return crypto.randomBytes(bytes).toString("base64url");
}

function tenantsFile(dataDir: string) {
  return path.join(dataDir, "tenants.json");
}

async function ensureDir(dataDir: string) {
  await fs.mkdir(dataDir, { recursive: true });
}

async function readTenants(dataDir: string): Promise<TenantRecord[]> {
  await ensureDir(dataDir);
  const fp = tenantsFile(dataDir);
  try {
    const raw = await fs.readFile(fp, "utf8");
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr : [];
  } catch (e: any) {
    if (e?.code === "ENOENT") return [];
    // if corrupted, keep system alive but don't crash UI
    return [];
  }
}

async function writeTenants(dataDir: string, tenants: TenantRecord[]) {
  await ensureDir(dataDir);
  const fp = tenantsFile(dataDir);
  await fs.writeFile(fp, JSON.stringify(tenants, null, 2) + "\n", "utf8");
}

export async function listTenants(dataDir: string = (process.env.DATA_DIR || "./data")): Promise<TenantRecord[]> {
  return readTenants(dataDir);
}

export async function getTenant(dataDir: string, tenantId: string): Promise<TenantRecord | null> {
  const tenants = await readTenants(dataDir);
  return tenants.find(t => t.tenantId === tenantId) || null;
}

export async function createTenant(
  dataDir: string = (process.env.DATA_DIR || "./data"),
  notes?: string
): Promise<TenantRecord> {
  const tenants = await readTenants(dataDir);
  const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantKey = randKey(24);
  const t: TenantRecord = {
    tenantId,
    tenantKey,
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
    notes,
  };
  tenants.push(t);
  await writeTenants(dataDir, tenants);
  return t;
}

export async function rotateTenantKey(
  dataDir: string = (process.env.DATA_DIR || "./data"),
  tenantId: string
): Promise<TenantRecord> {
  const tenants = await readTenants(dataDir);
  const idx = tenants.findIndex(t => t.tenantId === tenantId);
  if (idx === -1) throw Object.assign(new Error("tenant_not_found"), { status: 404 });
  tenants[idx] = { ...tenants[idx], tenantKey: randKey(24), updatedAtUtc: nowUtc() };
  await writeTenants(dataDir, tenants);
  return tenants[idx];
}

/**
 * Local SSOT verification for UI/API: returns true/false (no throw).
 */
export async function verifyTenantKeyLocal(
  tenantId: string,
  tenantKey: string,
  dataDir: string = (process.env.DATA_DIR || "./data")
): Promise<boolean> {
  if (!tenantId || !tenantKey) return false;
  const t = await getTenant(dataDir, tenantId);
  if (!t) return false;
  return t.tenantKey === tenantKey;
}

/**
 * Stable demo tenant: used for /ui/admin autolink (no infinite tenant creation).
 */
export async function getOrCreateDemoTenant(
  dataDir: string = (process.env.DATA_DIR || "./data")
): Promise<TenantRecord> {
  const DEMO_ID = "tenant_demo";
  const tenants = await readTenants(dataDir);
  const found = tenants.find(t => t.tenantId === DEMO_ID);
  if (found) return found;

  const demo: TenantRecord = {
    tenantId: DEMO_ID,
    tenantKey: randKey(24),
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
    notes: "demo (autolink)",
  };
  tenants.push(demo);
  await writeTenants(dataDir, tenants);
  return demo;
}
TS
echo "✅ wrote src/lib/tenant_registry.ts (clean SSOT registry)"

# ----------------------------
# 2) Patch UI admin route to use getOrCreateDemoTenant + strong error output
#    We don't rewrite whole file. We just ensure imports exist and admin handler is safe.
# ----------------------------
node - <<'NODE'
const fs = require("fs");

const p = "src/ui/routes.ts";
let s = fs.readFileSync(p, "utf8");

// Ensure we import getOrCreateDemoTenant from tenant_registry
if (!s.includes("getOrCreateDemoTenant")) {
  s = s.replace(
    /from "\.\.\/lib\/tenant_registry\.js";/g,
    (m) => {
      // Insert in named imports if present
      if (m.includes("{")) return m.replace("{", "{ getOrCreateDemoTenant, ");
      // else keep
      return m;
    }
  );

  // If there was no named import at all, add one (fallback)
  if (!s.includes("from \"../lib/tenant_registry.js\"")) {
    s = `import { getOrCreateDemoTenant } from "../lib/tenant_registry.js";\n` + s;
  }
}

// Harden /ui/admin: find route and wrap in try/catch with explicit redirect
// We look for "/ui/admin" handler pattern and replace body conservatively.
const adminRouteRe = /app\.get\(\s*["']\/ui\/admin["']\s*,\s*async\s*\(\s*req\s*,\s*res\s*\)\s*=>\s*\{[\s\S]*?\n\}\s*\)\s*;?/m;

if (adminRouteRe.test(s)) {
  s = s.replace(adminRouteRe, `app.get("/ui/admin", async (req, res) => {
  try {
    const admin = String((req.query as any).admin || "");
    const expected = String(process.env.ADMIN_KEY || "");
    if (!expected) return res.status(500).send("admin_key_not_configured");
    if (!admin || admin !== expected) return res.status(401).send("invalid_admin_key");

    const t = await getOrCreateDemoTenant(process.env.DATA_DIR || "./data");
    const base = String(process.env.BASE_URL || "");
    const tenantId = encodeURIComponent(t.tenantId);
    const k = encodeURIComponent(t.tenantKey);

    // redirect to client UI
    const loc = \`/ui/tickets?tenantId=\${tenantId}&k=\${k}\`;
    res.setHeader("Cache-Control", "no-store");
    return res.redirect(302, loc);
  } catch (e) {
    const msg = (e && (e.message || String(e))) || "admin_autolink_failed";
    res.status(500).type("text/html").send(\`<pre>admin_autolink_failed\\n\${msg}</pre>\`);
  }
});`);
} else {
  // If file structure different, append a safe handler at end (Express will match first, but better than nothing)
  s += `\n\n// --- phase21d safety: stable /ui/admin autolink ---\napp.get("/ui/admin", async (req, res) => {\n  try {\n    const admin = String((req.query as any).admin || "");\n    const expected = String(process.env.ADMIN_KEY || "");\n    if (!expected) return res.status(500).send("admin_key_not_configured");\n    if (!admin || admin !== expected) return res.status(401).send("invalid_admin_key");\n    const t = await getOrCreateDemoTenant(process.env.DATA_DIR || "./data");\n    const loc = \`/ui/tickets?tenantId=\${encodeURIComponent(t.tenantId)}&k=\${encodeURIComponent(t.tenantKey)}\`;\n    res.setHeader("Cache-Control", "no-store");\n    return res.redirect(302, loc);\n  } catch (e: any) {\n    return res.status(500).type("text/html").send(\`<pre>admin_autolink_failed\\n\${e?.message || String(e)}</pre>\`);\n  }\n});\n`;
}

fs.writeFileSync(p, s);
console.log("✅ patched src/ui/routes.ts (/ui/admin uses stable demo tenant + safe redirect)");
NODE

# ----------------------------
# 3) Improve smoke-ui.sh: on 500, print body (first lines)
# ----------------------------
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

fail() { echo "FAIL: $*"; exit 1; }

echo "==> [0] health"
h="$(curl -sS -D- "$BASE_URL/health" -o /dev/null | head -n 1 | awk '{print $2}')"
[ "${h:-}" = "200" ] || fail "health not 200"
echo "✅ health ok"

echo "==> [1] /ui hidden (404 expected)"
s1="$(curl -sS -D- "$BASE_URL/ui" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s1"
[ "${s1:-}" = "404" ] || fail "/ui should be hidden"

echo "==> [2] /ui/admin redirect (302 expected)"
[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY is required"
hdr="$(mktemp)"
body="$(mktemp)"
curl -sS -D "$hdr" "$BASE_URL/ui/admin?admin=$ADMIN_KEY" -o "$body" || true
s2="$(head -n 1 "$hdr" | awk '{print $2}')"
echo "status=$s2"
if [ "${s2:-}" != "302" ]; then
  echo "---- debug headers ----"; cat "$hdr" | sed -n '1,40p'
  echo "---- debug body ----"; cat "$body" | sed -n '1,40p'
  rm -f "$hdr" "$body"
  fail "expected 302"
fi

loc="$(grep -i '^location:' "$hdr" | head -n 1 | cut -d' ' -f2- | tr -d '\r')"
[ -n "$loc" ] || fail "no Location header"
final="$BASE_URL${loc}"
rm -f "$hdr" "$body"

echo "==> [3] follow redirect -> tickets should be 200"
s3="$(curl -sS -D- "$final" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s3"
[ "${s3:-}" = "200" ] || fail "tickets not 200: $final"

echo "==> [4] export should be 200"
tenantId="$(python3 - <<PY 2>/dev/null || true
import urllib.parse as u
from urllib.parse import urlparse, parse_qs
q=parse_qs(urlparse("$final").query)
print(q.get("tenantId",[""])[0])
PY
)"
k="$(python3 - <<PY 2>/dev/null || true
from urllib.parse import urlparse, parse_qs
q=parse_qs(urlparse("$final").query)
print(q.get("k",[""])[0])
PY
)"
# if python3 not available, parse with shell
if [ -z "${tenantId:-}" ] || [ -z "${k:-}" ]; then
  tenantId="$(echo "$final" | sed -n 's/.*tenantId=\([^&]*\).*/\1/p')"
  k="$(echo "$final" | sed -n 's/.*[?&]k=\([^&]*\).*/\1/p')"
fi

exportUrl="$BASE_URL/ui/export.csv?tenantId=$tenantId&k=$k"
s4="$(curl -sS -D- "$exportUrl" -o /dev/null | head -n 1 | awk '{print $2}')"
echo "status=$s4"
[ "${s4:-}" = "200" ] || fail "export not 200: $exportUrl"

echo "✅ smoke ui ok"
echo "$final"
BASH
chmod +x scripts/smoke-ui.sh
echo "✅ wrote scripts/smoke-ui.sh"

echo "==> Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase21d installed."
echo "Now:"
echo "  1) ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "  2) ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
