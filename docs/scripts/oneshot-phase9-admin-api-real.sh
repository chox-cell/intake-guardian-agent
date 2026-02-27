#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase9_${STAMP}"

echo "==> Phase9 OneShot (REAL admin API + durable keys) @ $ROOT"
echo "==> [0] Backup -> $BAK"
mkdir -p "$BAK"
cp -R src "$BAK/src" 2>/dev/null || true
cp tsconfig.json "$BAK/tsconfig.json" 2>/dev/null || true
mkdir -p scripts data

echo "==> [1] Ensure tsconfig excludes backups"
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "**/__bak_*", "**/__bak*/**"]));
fs.writeFileSync(p, JSON.stringify(j,null,2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE

echo "==> [2] Write src/api/admin-tenants.ts (REAL endpoints + data/admin.tenants.json)"
mkdir -p src/api
cat > src/api/admin-tenants.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { Express, Request, Response } from "express";

type TenantRec = {
  tenantId: string;
  key: string;
  createdAt: string;
  rotatedAt?: string;
};

function nowIso() { return new Date().toISOString(); }

function randId(prefix: string) {
  return `${prefix}_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
}

function randKey() {
  return crypto.randomBytes(16).toString("base64url");
}

function dataFile(dataDir: string) {
  return path.join(dataDir, "admin.tenants.json");
}

function readAll(dataDir: string): TenantRec[] {
  const fp = dataFile(dataDir);
  if (!fs.existsSync(fp)) return [];
  try {
    const raw = fs.readFileSync(fp, "utf8");
    const j = JSON.parse(raw);
    if (Array.isArray(j)) return j as TenantRec[];
    return [];
  } catch {
    return [];
  }
}

function writeAll(dataDir: string, rows: TenantRec[]) {
  const fp = dataFile(dataDir);
  fs.mkdirSync(path.dirname(fp), { recursive: true });
  fs.writeFileSync(fp, JSON.stringify(rows, null, 2) + "\n");
}

function pickAdminKey(req: Request) {
  // compat: query ?admin= ?ak= header x-admin-key
  const q = req.query as any;
  const fromQuery = (q.admin || q.ak || "") as string;
  const fromHeader = (req.headers["x-admin-key"] || "") as string;
  return String(fromQuery || fromHeader || "");
}

function requireAdmin(req: Request, res: Response): string | null {
  const envKey = process.env.ADMIN_KEY || "";
  const got = pickAdminKey(req);

  if (!envKey) {
    res.status(500).send("admin_key_not_configured");
    return null;
  }
  if (!got || got !== envKey) {
    res.status(401).send("admin_unauthorized");
    return null;
  }
  return envKey;
}

export function mountAdminTenantsApi(app: Express, args: { dataDir: string }) {
  const base = "/api/admin/tenants";

  // LIST
  app.get(base, (req, res) => {
    if (!requireAdmin(req, res)) return;
    const rows = readAll(args.dataDir);
    res.json({ ok: true, tenants: rows.map(r => ({ tenantId: r.tenantId, createdAt: r.createdAt, rotatedAt: r.rotatedAt })) });
  });

  // CREATE (always returns tenantId + key)
  app.post(`${base}/create`, (req, res) => {
    if (!requireAdmin(req, res)) return;
    const rows = readAll(args.dataDir);

    const tenantId = randId("tenant");
    const key = randKey();

    const rec: TenantRec = { tenantId, key, createdAt: nowIso() };
    rows.push(rec);
    writeAll(args.dataDir, rows);

    res.json({ ok: true, tenantId, key });
  });

  // ROTATE (requires tenantId)
  app.post(`${base}/rotate`, (req, res) => {
    if (!requireAdmin(req, res)) return;

    const body: any = req.body || {};
    const tenantId = String(body.tenantId || req.query.tenantId || "");
    if (!tenantId) return res.status(400).json({ ok: false, error: "missing_tenantId" });

    const rows = readAll(args.dataDir);
    const idx = rows.findIndex(r => r.tenantId === tenantId);
    if (idx === -1) return res.status(404).json({ ok: false, error: "tenant_not_found" });

    rows[idx].key = randKey();
    rows[idx].rotatedAt = nowIso();
    writeAll(args.dataDir, rows);

    res.json({ ok: true, tenantId, key: rows[idx].key });
  });
}
TS

echo "==> [3] Patch src/api/tenant-key.ts to fallback-read data/admin.tenants.json"
cat > src/api/tenant-key.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import type { Request } from "express";

export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

type AnyTenants = any;

function pickKeyFromReq(req: Request): string {
  const q: any = req.query || {};
  const fromQuery = q.k || q.key || "";
  const fromHeader = (req.headers["x-tenant-key"] || req.headers["authorization"] || "") as string;
  const fromBody = (req.body && (req.body.k || req.body.key)) || "";
  const auth = String(fromHeader || "");
  const authKey = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7) : auth;
  return String(fromQuery || fromBody || authKey || "");
}

function dataDirFromEnv() {
  return path.resolve(String(process.env.DATA_DIR || "./data"));
}

function readAdminTenantsKey(tenantId: string): string | null {
  try {
    const fp = path.join(dataDirFromEnv(), "admin.tenants.json");
    if (!fs.existsSync(fp)) return null;
    const rows = JSON.parse(fs.readFileSync(fp, "utf8"));
    if (!Array.isArray(rows)) return null;
    const rec = rows.find((r: any) => r && r.tenantId === tenantId);
    return rec?.key ? String(rec.key) : null;
  } catch {
    return null;
  }
}

function verifyWithTenantsStore(tenants: AnyTenants | undefined, tenantId: string, key: string): boolean {
  if (!tenants) return false;

  // common patterns (we try safely)
  try {
    if (typeof tenants.verify === "function") return !!tenants.verify(tenantId, key);
    if (typeof tenants.verifyKey === "function") return !!tenants.verifyKey(tenantId, key);
    if (typeof tenants.check === "function") return !!tenants.check(tenantId, key);
  } catch {}
  return false;
}

// Backward-compatible signature (2-4 args):
// requireTenantKey(req, tenantId)
// requireTenantKey(req, tenantId, tenantsStore)
// requireTenantKey(req, tenantId, tenantsStore, shares)
export function requireTenantKey(req: Request, tenantId: string, tenants?: AnyTenants, _shares?: any): string {
  const key = pickKeyFromReq(req);
  if (!key) throw new HttpError(401, "missing_tenant_key");

  // 1) if tenants store exists, verify there
  if (verifyWithTenantsStore(tenants, tenantId, key)) return key;

  // 2) fallback: admin.tenants.json
  const expected = readAdminTenantsKey(tenantId);
  if (expected && expected === key) return key;

  throw new HttpError(401, "invalid_tenant_key");
}

export function verifyTenantKey(req: Request, tenantId: string, tenants?: AnyTenants): boolean {
  try {
    requireTenantKey(req, tenantId, tenants);
    return true;
  } catch {
    return false;
  }
}
TS

echo "==> [4] Patch src/server.ts to mount Admin API (non-breaking) + keep UI mount"
node - <<'NODE'
const fs = require("fs");
const p = "src/server.ts";
let s = fs.readFileSync(p, "utf8");

// ensure import exists
if (!s.includes('mountAdminTenantsApi')) {
  // prefer .js style import like rest of repo
  if (s.includes('from "./ui/routes.js"')) {
    s = s.replace('from "./ui/routes.js";', 'from "./ui/routes.js";\nimport { mountAdminTenantsApi } from "./api/admin-tenants.js";');
  } else if (s.includes('from "./ui/routes"')) {
    s = s.replace('from "./ui/routes";', 'from "./ui/routes";\nimport { mountAdminTenantsApi } from "./api/admin-tenants";');
  } else {
    // fallback: add near top
    s = 'import { mountAdminTenantsApi } from "./api/admin-tenants.js";\n' + s;
  }
}

// mount before listen, after DATA_DIR is known
if (!s.includes("mountAdminTenantsApi(app")) {
  const needle = "app.listen";
  const idx = s.indexOf(needle);
  if (idx === -1) throw new Error("Could not find app.listen in src/server.ts");
  const inject = `\n  // Admin tenants API (real)\n  mountAdminTenantsApi(app as any, { dataDir: path.resolve(DATA_DIR) });\n`;
  s = s.slice(0, idx) + inject + s.slice(idx);
}

fs.writeFileSync(p, s);
console.log("✅ patched src/server.ts (mounted admin tenants api)");
NODE

echo "==> [5] Update scripts: demo-keys.sh uses admin create, prints client link"
cat > scripts/demo-keys.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-${ADMIN_KEY:-}}"

if [[ -z "${ADMIN_KEY:-}" ]]; then
  echo "❌ ADMIN_KEY missing. Run:"
  echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
  echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=$BASE_URL ./scripts/demo-keys.sh"
  exit 1
fi

echo "==> create tenant via admin api"
json="$(curl -sS -X POST "$BASE_URL/api/admin/tenants/create" -H "x-admin-key: $ADMIN_KEY")"
tenantId="$(node -p 'JSON.parse(process.argv[1]).tenantId' "$json")"
key="$(node -p 'JSON.parse(process.argv[1]).key' "$json")"

link="$BASE_URL/ui/tickets?tenantId=$tenantId&k=$key"
echo "✅ client link:"
echo "$link"
BASH
chmod +x scripts/demo-keys.sh

echo "==> [6] Write smoke-ui.sh (expects /ui hidden + /ui/admin 302 + tickets 200)"
cat > scripts/smoke-ui.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"
ADMIN_KEY="${ADMIN_KEY:-}"

echo "==> [1] /ui hidden (404)"
s1="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ui")"
echo "status=$s1"
[[ "$s1" == "404" ]] || { echo "FAIL: expected 404"; exit 1; }

echo "==> [2] /ui/admin should redirect (302) when admin key ok"
s2="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ui/admin?admin=$ADMIN_KEY")"
echo "status=$s2"
[[ "$s2" == "302" || "$s2" == "200" ]] || { echo "FAIL: expected 302/200"; curl -s "$BASE_URL/ui/admin?admin=$ADMIN_KEY" | head -n 40; exit 1; }

echo "==> [3] create tenant + open tickets (200)"
json="$(curl -sS -X POST "$BASE_URL/api/admin/tenants/create" -H "x-admin-key: $ADMIN_KEY")"
tenantId="$(node -p 'JSON.parse(process.argv[1]).tenantId' "$json")"
key="$(node -p 'JSON.parse(process.argv[1]).key' "$json")"

tickets="$BASE_URL/ui/tickets?tenantId=$tenantId&k=$key"
s3="$(curl -s -o /dev/null -w "%{http_code}" "$tickets")"
echo "status=$s3"
[[ "$s3" == "200" ]] || { echo "FAIL: expected 200"; curl -s "$tickets" | head -n 40; exit 1; }

echo "✅ smoke ok"
echo "client_ui: $tickets"
BASH
chmod +x scripts/smoke-ui.sh

echo "==> [7] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase9 installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
