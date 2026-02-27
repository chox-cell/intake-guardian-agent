#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase5b_${TS}"
mkdir -p "$BAK"

echo "==> Phase5b OneShot (fix factories + tenantkey compat + stable server) @ $ROOT"
echo "==> [0] Backup"
cp -f src/server.ts "$BAK/server.ts.bak" 2>/dev/null || true
cp -f src/api/tenant-key.ts "$BAK/tenant-key.ts.bak" 2>/dev/null || true

echo "==> [1] Patch src/api/tenant-key.ts to be backward-compatible (2-4 args + verifyTenantKey)"
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
 * Accepts (req, tenantId, tenants?, shares?)
 * - Header: x-tenant-key
 * - Query:  ?k=
 * - Body:   k=
 *
 * Returns tenantKey string on success.
 * Throws HttpError(status,message) on failure.
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

echo "==> [2] Detect factories + store module from your repo (no guessing)"
node - <<'NODE'
const fs = require("fs");
const path = require("path");

function read(p){ return fs.readFileSync(p,"utf8"); }
function pickFactory(file, prefer){
  const s = read(file);
  // try named export functions
  const re = /export\s+(?:async\s+)?function\s+([A-Za-z0-9_]+)\s*\(/g;
  const all = [];
  let m;
  while((m=re.exec(s))) all.push(m[1]);
  const preferred = all.find(n => prefer.some(x => n.toLowerCase().includes(x)));
  return preferred || all[0] || null;
}

function pickStoreModule(){
  const candidates = [
    "src/store/store.ts",
    "src/store/file_store.ts",
    "src/store/index.ts"
  ].map(p=>path.resolve(p)).filter(fs.existsSync);

  if (!candidates.length) return null;

  // Pick first file that exports a class
  for (const f of candidates){
    const s = read(f);
    const cm = s.match(/export\s+class\s+([A-Za-z0-9_]+)/);
    if (cm) {
      const className = cm[1];
      const rel = "./" + path.relative(path.resolve("src"), f).replace(/\\/g,"/").replace(/\.ts$/, ".js");
      // detect ctor shape
      const ctor = s.match(/constructor\s*\(([^)]*)\)/);
      const ctorArgs = ctor ? ctor[1] : "";
      const ctorStyle =
        ctorArgs.includes("{") || ctorArgs.includes("opts") || ctorArgs.includes("dataDir") && ctorArgs.includes(":")
          ? "object"
          : (ctorArgs.includes("dataDir") ? "string" : "object");
      return { relImport: rel, className, ctorStyle };
    }
  }
  return null;
}

const routesFile = path.resolve("src/api/routes.ts");
const adaptersFile = path.resolve("src/api/adapters.ts");
if (!fs.existsSync(routesFile)) throw new Error("missing src/api/routes.ts");
if (!fs.existsSync(adaptersFile)) throw new Error("missing src/api/adapters.ts");

const makeRoutes = pickFactory(routesFile, ["routes", "makeroutes", "makeRoutes"]);
const makeAdapters = pickFactory(adaptersFile, ["adapters", "makeadapters", "makeAdapters"]);

const store = pickStoreModule();
if (!makeRoutes) throw new Error("could not detect routes factory export in src/api/routes.ts");
if (!makeAdapters) throw new Error("could not detect adapters factory export in src/api/adapters.ts");
if (!store) throw new Error("could not detect store module under src/store/*.ts");

const out = { makeRoutes, makeAdapters, store };
fs.writeFileSync(".phase5b.detect.json", JSON.stringify(out,null,2));
console.log("✅ detected:", out);
NODE

echo "==> [3] Rewrite src/server.ts using detected names + safe casts (as any)"
node - <<'NODE'
const fs = require("fs");
const det = JSON.parse(fs.readFileSync(".phase5b.detect.json","utf8"));

const makeRoutesName = det.makeRoutes;
const makeAdaptersName = det.makeAdapters;
const storeRel = det.store.relImport;      // e.g. ./store/store.js
const storeClass = det.store.className;   // e.g. Store / FileStore / WorkStore
const ctorStyle = det.store.ctorStyle;    // "object" or "string"

const storeCtorLine =
  ctorStyle === "string"
    ? `  const store = new ${storeClass}(path.resolve(DATA_DIR));`
    : `  const store = new ${storeClass}({ dataDir: path.resolve(DATA_DIR) } as any);`;

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
${storeCtorLine}

  // UI (Phase4/5 behavior is inside src/ui/routes.ts)
  mountUI(app, { store, tenants } as any);

  // API routes (cast to any to avoid strict excess-props mismatch across versions)
  app.use("/api", ${makeRoutesName}({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS, tenants } as any));
  app.use("/api/adapters", ${makeAdaptersName}({ store, presetId: PRESET_ID, dedupeWindowSeconds: DEDUPE_WINDOW_SECONDS, tenants } as any));

  app.get("/health", (_req, res) => res.json({ ok: true }));

  app.listen(PORT, () => {
    logger.info(
      {
        PORT,
        DATA_DIR,
        PRESET_ID,
        DEDUPE_WINDOW_SECONDS,
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
console.log("✅ wrote src/server.ts (phase5b stable)");
NODE

echo "==> [4] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase5b OK."
echo "Now run:"
echo "  pnpm dev"
echo "Then:"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
