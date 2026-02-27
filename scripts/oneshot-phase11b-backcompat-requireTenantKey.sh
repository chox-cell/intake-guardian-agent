#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ts() { date +"%Y%m%d_%H%M%S"; }
BAK="__bak_phase11b_$(ts)"
echo "==> Phase11b OneShot (back-compat requireTenantKey signature) @ $ROOT"
echo "==> [0] Backup -> $BAK"
mkdir -p "$BAK"
cp -R src/api/tenant-key.ts "$BAK"/ 2>/dev/null || true

echo "==> [1] Overwrite src/api/tenant-key.ts (accept 2-4 args; ignore extras)"
cat > src/api/tenant-key.ts <<'TS'
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import type { Request } from "express";

export type HttpError = { status: number; message: string; code?: string };

function httpError(status: number, message: string, code?: string): HttpError {
  return { status, message, code };
}

function getDataDir(): string {
  return process.env.DATA_DIR || "./data";
}

function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

const REGISTRY_FILE = "tenant_keys.json";

export type TenantRegistry = {
  version: number;
  updatedAt: string;
  tenants: Record<string, { key: string; createdAt: string }>;
};

function registryPath(): string {
  return path.resolve(getDataDir(), REGISTRY_FILE);
}

export function loadRegistry(): TenantRegistry {
  const p = registryPath();
  ensureDir(path.dirname(p));
  if (!fs.existsSync(p)) {
    const empty: TenantRegistry = { version: 1, updatedAt: new Date().toISOString(), tenants: {} };
    fs.writeFileSync(p, JSON.stringify(empty, null, 2) + "\n");
    return empty;
  }
  try {
    const raw = fs.readFileSync(p, "utf8");
    const j = JSON.parse(raw);
    if (!j || typeof j !== "object") throw new Error("bad_registry");
    j.version = typeof j.version === "number" ? j.version : 1;
    j.updatedAt = typeof j.updatedAt === "string" ? j.updatedAt : new Date().toISOString();
    j.tenants = j.tenants && typeof j.tenants === "object" ? j.tenants : {};
    return j as TenantRegistry;
  } catch {
    const reset: TenantRegistry = { version: 1, updatedAt: new Date().toISOString(), tenants: {} };
    fs.writeFileSync(p, JSON.stringify(reset, null, 2) + "\n");
    return reset;
  }
}

export function saveRegistry(reg: TenantRegistry) {
  reg.updatedAt = new Date().toISOString();
  fs.writeFileSync(registryPath(), JSON.stringify(reg, null, 2) + "\n");
}

export function createTenantInRegistry(): { tenantId: string; tenantKey: string } {
  const reg = loadRegistry();
  const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantKey = crypto.randomBytes(24).toString("base64url");
  reg.tenants[tenantId] = { key: tenantKey, createdAt: new Date().toISOString() };
  saveRegistry(reg);
  return { tenantId, tenantKey };
}

function constantTimeEq(a: string, b: string) {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return crypto.timingSafeEqual(ab, bb);
}

export function extractTenantKey(req: Request): string | null {
  const q: any = (req as any).query || {};
  if (typeof q.k === "string" && q.k.length > 0) return q.k;
  if (typeof q.key === "string" && q.key.length > 0) return q.key;

  const h = req.headers["x-tenant-key"];
  if (typeof h === "string" && h.length > 0) return h;

  const auth = req.headers["authorization"];
  if (typeof auth === "string" && auth.toLowerCase().startsWith("bearer ")) {
    const v = auth.slice(7).trim();
    if (v) return v;
  }

  const body: any = (req as any).body;
  if (body && typeof body.key === "string" && body.key.length > 0) return body.key;

  return null;
}

/**
 * Backward-compatible signature:
 * - new:  requireTenantKey(req, tenantId)
 * - old:  requireTenantKey(req, tenantId, tenantsStore?, sharesStore?)
 * We ignore extra args on purpose so legacy call sites compile.
 */
export function requireTenantKey(req: Request, tenantId: string, _tenants?: any, _shares?: any): string {
  if (!tenantId) throw httpError(400, "missing_tenantId", "missing_tenantId");
  const key = extractTenantKey(req);
  if (!key) throw httpError(401, "missing_tenant_key", "missing_tenant_key");

  const reg = loadRegistry();
  const rec = reg.tenants[tenantId];
  if (!rec || !rec.key) throw httpError(401, "invalid_tenant_key", "invalid_tenant_key");
  if (!constantTimeEq(rec.key, key)) throw httpError(401, "invalid_tenant_key", "invalid_tenant_key");
  return key;
}

export function isAdminKeyOk(req: Request): boolean {
  const adminKey = process.env.ADMIN_KEY;
  if (!adminKey) return false;
  const q: any = (req as any).query || {};
  const inQuery = typeof q.admin === "string" ? q.admin : "";
  const inHeader = typeof req.headers["x-admin-key"] === "string" ? (req.headers["x-admin-key"] as string) : "";
  const v = inQuery || inHeader;
  if (!v) return false;
  return constantTimeEq(adminKey, v);
}
TS

echo "==> [2] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase11b OK."
echo "Now run:"
echo "  ADMIN_KEY=super_secret_admin_123 pnpm dev"
echo "Then:"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
echo "  ADMIN_KEY=super_secret_admin_123 BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
