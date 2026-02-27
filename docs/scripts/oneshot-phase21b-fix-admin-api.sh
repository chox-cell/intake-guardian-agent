#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ts() { date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase21b_$(ts)"
echo "==> Phase21b OneShot (fix admin.ts + tenant_registry contract) @ $ROOT"
mkdir -p "$BAK"
cp -R src "$BAK/src" 2>/dev/null || true
cp -R scripts "$BAK/scripts" 2>/dev/null || true
cp tsconfig.json "$BAK/tsconfig.json" 2>/dev/null || true
echo "✅ backup -> $BAK"

# --- [1] Ensure tsconfig excludes backups ---
node - <<'NODE'
const fs = require("fs");
const p = "tsconfig.json";
const j = JSON.parse(fs.readFileSync(p,"utf8"));
j.exclude = Array.from(new Set([...(j.exclude||[]), "__bak_*", "dist", "node_modules"]));
fs.writeFileSync(p, JSON.stringify(j,null,2) + "\n");
console.log("✅ patched tsconfig.json exclude");
NODE

# --- [2] Write src/lib/tenant_registry.ts (stable, backward compatible) ---
mkdir -p src/lib
cat > src/lib/tenant_registry.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type TenantRecord = {
  tenantId: string;
  tenantKey: string;
  createdAtUtc: string;
  updatedAtUtc: string;
  notes?: string;
};

const DEFAULT_DATA_DIR = process.env.DATA_DIR || "./data";
const TENANTS_FILE = "tenants.json";

function nowUtc() {
  return new Date().toISOString();
}

function ensureDir(dir: string) {
  fs.mkdirSync(dir, { recursive: true });
}

function tenantsPath(dataDir: string) {
  return path.join(dataDir, TENANTS_FILE);
}

function safeReadJson<T>(p: string, fallback: T): T {
  try {
    if (!fs.existsSync(p)) return fallback;
    const raw = fs.readFileSync(p, "utf8");
    if (!raw.trim()) return fallback;
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function safeWriteJson(p: string, obj: unknown) {
  fs.writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
}

function genId(prefix: string) {
  // short + stable
  const r = crypto.randomBytes(6).toString("hex");
  return `${prefix}_${Date.now()}_${r}`;
}

function genKey() {
  // URL-safe-ish
  return crypto.randomBytes(24).toString("base64url");
}

async function loadTenants(dataDir: string): Promise<TenantRecord[]> {
  ensureDir(dataDir);
  const p = tenantsPath(dataDir);
  return safeReadJson<TenantRecord[]>(p, []);
}

async function saveTenants(dataDir: string, tenants: TenantRecord[]): Promise<void> {
  ensureDir(dataDir);
  const p = tenantsPath(dataDir);
  safeWriteJson(p, tenants);
}

/**
 * Backward-compatible signature:
 * - listTenants() OR listTenants(dataDir)
 */
export async function listTenants(dataDir: string = DEFAULT_DATA_DIR): Promise<TenantRecord[]> {
  return await loadTenants(dataDir);
}

/**
 * Backward-compatible signature:
 * - createTenant() OR createTenant(dataDir) OR createTenant(dataDir, notes)
 * - createTenant(undefined, notes) also works
 */
export async function createTenant(
  a?: string,
  b?: string
): Promise<TenantRecord> {
  const dataDir = (typeof a === "string" && a.length) ? a : DEFAULT_DATA_DIR;
  const notes = (typeof a === "string" && a.length && typeof b === "string") ? b : (typeof a === "string" && (!b) && a.startsWith("./") ? "" : (typeof b === "string" ? b : (typeof a === "string" && !a.startsWith("./") ? a : "")));

  const tenants = await loadTenants(dataDir);
  const t: TenantRecord = {
    tenantId: genId("tenant"),
    tenantKey: genKey(),
    createdAtUtc: nowUtc(),
    updatedAtUtc: nowUtc(),
    notes: notes || undefined,
  };
  tenants.push(t);
  await saveTenants(dataDir, tenants);
  return t;
}

export async function getTenant(tenantId: string, dataDir: string = DEFAULT_DATA_DIR): Promise<TenantRecord | null> {
  const tenants = await loadTenants(dataDir);
  return tenants.find(t => t.tenantId === tenantId) || null;
}

export async function rotateTenantKey(tenantId: string, dataDir: string = DEFAULT_DATA_DIR): Promise<TenantRecord | null> {
  const tenants = await loadTenants(dataDir);
  const idx = tenants.findIndex(t => t.tenantId === tenantId);
  if (idx === -1) return null;
  tenants[idx] = {
    ...tenants[idx],
    tenantKey: genKey(),
    updatedAtUtc: nowUtc(),
  };
  await saveTenants(dataDir, tenants);
  return tenants[idx];
}

/**
 * Sync local verifier for request-time gating (UI).
 * Reads from tenants.json directly (no cache), so it's always consistent.
 */
export function verifyTenantKeyLocal(tenantId: string, tenantKey: string, dataDir: string = DEFAULT_DATA_DIR): boolean {
  try {
    ensureDir(dataDir);
    const p = tenantsPath(dataDir);
    const tenants = safeReadJson<TenantRecord[]>(p, []);
    const t = tenants.find(x => x.tenantId === tenantId);
    return !!t && t.tenantKey === tenantKey;
  } catch {
    return false;
  }
}
TS
echo "✅ wrote src/lib/tenant_registry.ts"

# --- [3] Write src/api/admin.ts (await-safe + exports match) ---
mkdir -p src/api
cat > src/api/admin.ts <<'TS'
import type { Express, Request, Response } from "express";
import { createTenant, listTenants, rotateTenantKey, getTenant } from "../lib/tenant_registry.js";

function adminKeyOk(req: Request) {
  const expected = process.env.ADMIN_KEY || "";
  if (!expected) return false;
  const q = (req.query.admin as string) || "";
  const h = (req.headers["x-admin-key"] as string) || "";
  const a = (req.headers["authorization"] as string) || "";
  const bearer = a.toLowerCase().startsWith("bearer ") ? a.slice(7) : "";
  return q === expected || h === expected || bearer === expected;
}

function deny(res: Response, code = 401, msg = "unauthorized") {
  return res.status(code).json({ ok: false, error: msg });
}

export function mountAdminApi(app: Express) {
  // GET /api/admin/tenants
  app.get("/api/admin/tenants", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const tenants = await listTenants();
    return res.json({
      ok: true,
      tenants: tenants.map(t => ({
        tenantId: t.tenantId,
        tenantKey: t.tenantKey, // admin only
        createdAtUtc: t.createdAtUtc,
        updatedAtUtc: t.updatedAtUtc,
        notes: t.notes || null,
      })),
    });
  });

  // GET /api/admin/tenants/:id
  app.get("/api/admin/tenants/:id", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const tenantId = req.params.id;
    const t = await getTenant(tenantId);
    if (!t) return deny(res, 404, "tenant_not_found");
    return res.json({ ok: true, tenant: t });
  });

  // POST /api/admin/tenants  { notes? }
  app.post("/api/admin/tenants", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const notes = (req.body && typeof req.body.notes === "string") ? req.body.notes : "";
    const t = await createTenant(undefined, notes);
    return res.json({ ok: true, tenantId: t.tenantId, tenantKey: t.tenantKey });
  });

  // POST /api/admin/tenants/:id/rotate
  app.post("/api/admin/tenants/:id/rotate", async (req, res) => {
    if (!adminKeyOk(req)) return deny(res);
    const tenantId = req.params.id;
    const t = await rotateTenantKey(tenantId);
    if (!t) return deny(res, 404, "tenant_not_found");
    return res.json({ ok: true, tenantId: t.tenantId, tenantKey: t.tenantKey });
  });
}
TS
echo "✅ wrote src/api/admin.ts"

# --- [4] Typecheck ---
echo "==> Typecheck"
pnpm -s lint:types
echo "✅ Phase21b installed."
echo "Run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "And (optional admin api):"
echo "  curl -s 'http://127.0.0.1:7090/api/admin/tenants?admin=super_secret_admin_123' | cat"
