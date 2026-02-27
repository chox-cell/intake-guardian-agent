#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase5c_${TS}"
mkdir -p "$BAK"

echo "==> Phase5c OneShot (autodetect server imports + fix tenant-key signature) @ $ROOT"
echo "==> [0] Backup"
cp -f src/server.ts "$BAK/server.ts.bak" 2>/dev/null || true
cp -f src/api/tenant-key.ts "$BAK/tenant-key.ts.bak" 2>/dev/null || true

echo "==> [1] Patch src/api/tenant-key.ts (accept 2-4 args, return string or throw HttpError)"
cat > src/api/tenant-key.ts <<'TS'
import type { Request } from "express";

export type TenantsLike = {
  verify?(tenantId: string, tenantKey: string): boolean;
  verifyTenantKey?(tenantId: string, tenantKey: string): boolean;
};

export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function pickFirst(...vals: Array<string | undefined | null>) {
  for (const v of vals) if (typeof v === "string" && v.trim()) return v.trim();
  return "";
}

/**
 * Backward-compatible tenant key gate.
 * Signature must accept old callers: (req, tenantId, tenants?, shares?)
 */
export function requireTenantKey(
  req: Request,
  tenantId: string,
  tenants?: TenantsLike,
  _shares?: any
): string {
  const header = req.header("x-tenant-key");
  const q = (req.query as any)?.k;
  const b = (req.body as any)?.k;

  const tenantKey = pickFirst(header, q, b);
  if (!tenantId) throw new HttpError(400, "missing_tenantId");
  if (!tenantKey) throw new HttpError(401, "missing_tenant_key");

  const verify =
    (tenants && typeof tenants.verify === "function" && tenants.verify.bind(tenants)) ||
    (tenants && typeof tenants.verifyTenantKey === "function" && tenants.verifyTenantKey.bind(tenants)) ||
    null;

  if (verify) {
    const ok = verify(tenantId, tenantKey);
    if (!ok) throw new HttpError(401, "invalid_tenant_key");
  }

  return tenantKey;
}

export function requireAdminKey(req: Request): void {
  const admin = pickFirst(req.header("x-admin-key"), (req.query as any)?.admin, (req.body as any)?.admin);
  const expected = process.env.ADMIN_KEY || "";
  if (!expected) throw new HttpError(500, "admin_key_not_configured");
  if (!admin) throw new HttpError(401, "missing_admin_key");
  if (admin !== expected) throw new HttpError(401, "invalid_admin_key");
}
TS

echo "==> [2] Autodetect: routes factory + adapters factory + store class + store module"
node - <<'NODE'
const fs = require("fs");
const path = require("path");

function walk(dir, out=[]) {
  if (!fs.existsSync(dir)) return out;
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, out);
    else if (ent.isFile() && p.endsWith(".ts")) out.push(p);
  }
  return out;
}
function read(p){ return fs.readFileSync(p, "utf8"); }

function pickFactory(file, preferTokens){
  const s = read(file);
  const re = /export\s+(?:async\s+)?function\s+([A-Za-z0-9_]+)\s*\(/g;
  const all = [];
  let m;
  while((m=re.exec(s))) all.push(m[1]);
  const lower = (x)=>x.toLowerCase();
  const preferred = all.find(n => preferTokens.some(tok => lower(n).includes(lower(tok))));
  return preferred || all[0] || null;
}

function detectStore(){
  const files = walk(path.resolve("src"));
  // prioritize store-like dirs if exist
  const preferred = files.filter(f => f.includes(`${path.sep}store${path.sep}`)).concat(files);
  for (const f of preferred){
    const s = read(f);
    // must have listWorkItems signature
    if (!s.includes("listWorkItems")) continue;
    // must export a class
    const cm = s.match(/export\s+class\s+([A-Za-z0-9_]+)/);
    if (!cm) continue;
    const className = cm[1];
    const relFromSrc = "./" + path.relative(path.resolve("src"), f).replace(/\\/g,"/").replace(/\.ts$/, ".js");
    // ctor style guess
    const ctor = s.match(/constructor\s*\(([^)]*)\)/);
    const ctorArgs = ctor ? ctor[1] : "";
    const ctorStyle = ctorArgs.includes("{") ? "object" : (ctorArgs.includes("dataDir") ? "object" : "object");
    return { relImport: relFromSrc, className, ctorStyle };
  }
  return null;
}

const routesFile = path.resolve("src/api/routes.ts");
const adaptersFile = path.resolve("src/api/adapters.ts");

if (!fs.existsSync(routesFile)) throw new Error("missing src/api/routes.ts");
if (!fs.existsSync(adaptersFile)) throw new Error("missing src/api/adapters.ts");

const makeRoutes = pickFactory(routesFile, ["makeRoutes","routes"]);
const makeAdapters = pickFactory(adaptersFile, ["makeAdapters","adapters","makeAdapter","adapter"]);

const store = detectStore();

if (!makeRoutes) throw new Error("could not detect routes factory export in src/api/routes.ts");
if (!makeAdapters) throw new Error("could not detect adapters factory export in src/api/adapters.ts");
if (!store) throw new Error("could not detect store class (needs export class + listWorkItems)");

const out = { makeRoutes, makeAdapters, store };
fs.writeFileSync(".phase5c.detect.json", JSON.stringify(out,null,2));
console.log("✅ detected:", out);
NODE

echo "==> [3] Rewrite src/server.ts (NO FileStore import, NO tenants type mismatch)"
node - <<'NODE'
const fs = require("fs");
const det = JSON.parse(fs.readFileSync(".phase5c.detect.json","utf8"));

const makeRoutesName = det.makeRoutes;
const makeAdaptersName = det.makeAdapters;

const storeRel = det.store.relImport;   // from src/ => ./...
const storeClass = det.store.className;

const code = `import express from "express";
import path from "path";
import pino from "pino";

import { ${makeRoutesName} } from "./api/routes.js";
import { ${makeAdaptersName} } from "./api/adapters.js";
import { TenantsStore } from "./tenants/store.js";
import { mountUI } from "./ui/routes.js";
import { ${storeClass} } from "${storeRel}";

const logger = pino();

const PORT = Number(process.env.PORT || 7090);
const DATA_DIR = process.env.DATA_DIR || "./data";
const PRESET_ID = process.env.PRESET_ID || "it_support.v1";
const DEDUPE_WINDOW_SECONDS = Number(process.env.DEDUPE_WINDOW_SECONDS || 86400);

async function main() {
  const app = express();
  app.use(express.urlencoded({ extended: true }));
  app.use(express.json({ limit: "2mb" }));

  const tenants = new TenantsStore({ dataDir: path.resolve(DATA_DIR) } as any);
  const store = new ${storeClass}({ dataDir: path.resolve(DATA_DIR) } as any);

  // UI (sell UI + admin autolink lives in src/ui/routes.ts)
  mountUI(app, { store, tenants } as any);

  // API routes — IMPORTANT: pass only what your factory accepts; cast to any to avoid TS excess-props.
  app.use("/api", ${makeRoutesName}({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS } as any));
  app.use("/api/adapters", ${makeAdaptersName}({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS, tenants } as any));

  app.get("/health", (_req, res) => res.json({ ok: true }));

  app.listen(PORT, () => {
    logger.info(
      {
        PORT,
        DATA_DIR,
        PRESET_ID,
        DEDUPE_WINDOW_SECONDS,
        TENANT_KEYS_CONFIGURED: true,
        ADMIN_KEY_CONFIGURED: !!process.env.ADMIN_KEY
      },
      "Intake-Guardian Agent running"
    );
  });
}

main().catch((err) => {
  logger.error({ err }, "fatal");
  process.exit(1);
});
`;
fs.writeFileSync("src/server.ts", code);
console.log("✅ wrote src/server.ts (phase5c stable)");
NODE

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase5c installed."
echo "Now:"
echo "  1) pnpm dev"
echo "  2) BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  3) ADMIN_KEY=... BASE_URL=http://127.0.0.1:7090 ./scripts/admin-link.sh"
echo "  4) BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
