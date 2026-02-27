#!/usr/bin/env bash
set -euo pipefail

echo "==> Phase22 OneShot (fix tenant_demo tenantKey=undefined) @ $(pwd)"
bak="__bak_phase22_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$bak"
cp -R src scripts tsconfig.json package.json "$bak/" 2>/dev/null || true
echo "✅ backup -> $bak"

echo "==> [1] Ensure tsconfig excludes backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.isArray(j.exclude) ? j.exclude : [];
const need = ["__bak_*","dist","node_modules"];
for (const x of need) if (!j.exclude.includes(x)) j.exclude.push(x);
fs.writeFileSync(p, JSON.stringify(j,null,2)+"\n");
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Overwrite src/lib/tenant_registry.ts with strict SSOT contract"
cat > src/lib/tenant_registry.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TenantRecord = {
  tenantId: string;
  tenantKey: string;
  notes?: string;
  createdAtUtc: string;
  updatedAtUtc: string;
};

const DEFAULT_DATA_DIR = process.env.DATA_DIR || "./data";
const TENANTS_FILE = "tenants.json";

function nowUtc() {
  return new Date().toISOString();
}

function ensureDir(dir: string) {
  fs.mkdirSync(dir, { recursive: true });
}

function filePath(dataDir: string) {
  return path.join(dataDir, TENANTS_FILE);
}

function randKey(bytes = 24) {
  // url-safe-ish
  return crypto.randomBytes(bytes).toString("base64url");
}

function readAll(dataDir = DEFAULT_DATA_DIR): TenantRecord[] {
  ensureDir(dataDir);
  const fp = filePath(dataDir);
  if (!fs.existsSync(fp)) return [];
  const raw = fs.readFileSync(fp, "utf8").trim();
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    if (Array.isArray(v)) return v as TenantRecord[];
    if (v && Array.isArray((v as any).tenants)) return (v as any).tenants as TenantRecord[];
    return [];
  } catch {
    return [];
  }
}

function writeAll(dataDir = DEFAULT_DATA_DIR, tenants: TenantRecord[]) {
  ensureDir(dataDir);
  const fp = filePath(dataDir);
  fs.writeFileSync(fp, JSON.stringify({ tenants }, null, 2) + "\n");
}

export async function listTenants(dataDir = DEFAULT_DATA_DIR): Promise<TenantRecord[]> {
  return readAll(dataDir);
}

export async function getTenant(dataDir = DEFAULT_DATA_DIR, tenantId: string): Promise<TenantRecord | null> {
  const tenants = readAll(dataDir);
  return tenants.find(t => t.tenantId === tenantId) || null;
}

export async function createTenant(dataDirOrNotes?: string, maybeNotes?: string): Promise<TenantRecord> {
  // Backward compatible:
  // - createTenant("notes")  -> uses DEFAULT_DATA_DIR
  // - createTenant(dataDir, "notes")
  let dataDir = DEFAULT_DATA_DIR;
  let notes = "";

  if (typeof dataDirOrNotes === "string" && typeof maybeNotes === "string") {
    dataDir = dataDirOrNotes;
    notes = maybeNotes;
  } else if (typeof dataDirOrNotes === "string" && typeof maybeNotes === "undefined") {
    dataDir = DEFAULT_DATA_DIR;
    notes = dataDirOrNotes;
  }

  const tenants = readAll(dataDir);
  const t: TenantRecord = {
    tenantId: `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`,
    tenantKey: randKey(24),
    notes: notes || undefined,
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
  };
  tenants.unshift(t);
  writeAll(dataDir, tenants);
  return t;
}

export async function rotateTenantKey(dataDir = DEFAULT_DATA_DIR, tenantId: string): Promise<TenantRecord | null> {
  const tenants = readAll(dataDir);
  const idx = tenants.findIndex(t => t.tenantId === tenantId);
  if (idx === -1) return null;
  tenants[idx] = { ...tenants[idx], tenantKey: randKey(24), updatedAtUtc: nowUtc() };
  writeAll(dataDir, tenants);
  return tenants[idx];
}

export function verifyTenantKeyLocal(tenantId: string, tenantKey: string): boolean {
  if (!tenantId || !tenantKey) return false;
  const tenants = readAll(DEFAULT_DATA_DIR);
  const t = tenants.find(x => x.tenantId === tenantId);
  if (!t) return false;
  // strict compare (no require/ESM issues)
  return t.tenantKey === tenantKey;
}

export async function getOrCreateDemoTenant(dataDir = DEFAULT_DATA_DIR): Promise<TenantRecord> {
  const DEMO_ID = "tenant_demo";
  const tenants = readAll(dataDir);
  const idx = tenants.findIndex(t => t.tenantId === DEMO_ID);

  // If exists but missing/invalid key -> repair
  if (idx !== -1) {
    const cur = tenants[idx] as any;
    const fixedKey = (typeof cur.tenantKey === "string" && cur.tenantKey.length >= 10) ? cur.tenantKey : randKey(24);
    const fixed: TenantRecord = {
      tenantId: DEMO_ID,
      tenantKey: fixedKey,
      notes: cur.notes || "Demo tenant (auto)",
      createdAtUtc: cur.createdAtUtc || nowUtc(),
      updatedAtUtc: nowUtc(),
    };
    tenants[idx] = fixed;
    writeAll(dataDir, tenants);
    return fixed;
  }

  // Create demo tenant
  const t: TenantRecord = {
    tenantId: DEMO_ID,
    tenantKey: randKey(24),
    notes: "Demo tenant (auto)",
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
  };
  tenants.unshift(t);
  writeAll(dataDir, tenants);
  return t;
}
TS
echo "✅ wrote src/lib/tenant_registry.ts"

echo "==> [3] Patch src/ui/routes.ts to hard-guard tenantKey and repair demo tenant"
node - <<'NODE'
const fs = require("fs");
const p = "src/ui/routes.ts";
let s = fs.readFileSync(p,"utf8");

// Ensure we import getOrCreateDemoTenant (already there usually). If missing, add.
if (!s.includes("getOrCreateDemoTenant")) {
  s = s.replace(
    /import\s+\{([^}]+)\}\s+from\s+"\.\.\/lib\/tenant_registry\.js";/,
    (m, inner) => {
      const parts = inner.split(",").map(x=>x.trim()).filter(Boolean);
      if (!parts.includes("getOrCreateDemoTenant")) parts.push("getOrCreateDemoTenant");
      return `import { ${parts.join(", ")} } from "../lib/tenant_registry.js";`;
    }
  );
}

// Replace redirect builder to guarantee tenantKey exists (robust)
s = s.replace(
  /return\s+res\.redirect\(302,\s*`\/ui\/tickets\?tenantId=\$\{encodeURIComponent\(tenant\.tenantId\)\}&k=\$\{encodeURIComponent$begin:math:text$tenant\\\.tenantKey$end:math:text$\}`\);/g,
  `{
    const tk = (tenant && (tenant as any).tenantKey) ? String((tenant as any).tenantKey) : "";
    if (!tk || tk === "undefined") {
      // repair demo tenant key if needed
      const repaired = await getOrCreateDemoTenant();
      const rtk = String((repaired as any).tenantKey || "");
      if (!rtk || rtk === "undefined") {
        return res.status(500).send("autolink_failed: tenantKey_missing");
      }
      return res.redirect(302, \`/ui/tickets?tenantId=\${encodeURIComponent(repaired.tenantId)}&k=\${encodeURIComponent(rtk)}\`);
    }
    return res.redirect(302, \`/ui/tickets?tenantId=\${encodeURIComponent(tenant.tenantId)}&k=\${encodeURIComponent(tk)}\`);
  }`
);

fs.writeFileSync(p, s);
console.log("✅ patched src/ui/routes.ts (tenantKey guard + repair)");
NODE

echo "==> [4] Patch scripts/smoke-ui.sh to fail if k=undefined"
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
loc="$(echo "$hdr" | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r\n')"
echo "status=$code"
[ "$code" = "302" ] || { echo "$hdr" | head -n 20; fail "expected 302"; }
[ -n "$loc" ] || fail "no Location header"

final="$BASE_URL$(echo "$loc" | sed 's#^/##; s#^#/#')"
# Normalize if Location is absolute
if echo "$loc" | grep -qE '^https?://'; then final="$loc"; fi

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

echo "==> [5] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase22 installed."
echo "Now run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
