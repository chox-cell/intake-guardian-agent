import type { Request } from "express";
import { verifyTenantKeyLocal } from "../lib/tenant_registry.js";

export class HttpError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message?: string) {
    super(message || code);
    this.status = status;
    this.code = code;
  }
}

function extractTenantKey(req: Request): string {
  // priority: query k -> header -> bearer -> body
  const q = (req.query as any)?.k;
  if (typeof q === "string" && q) return q;

  const h = req.header("x-tenant-key") || req.header("x-tenant") || "";
  if (h) return h;

  const a = req.header("authorization") || "";
  if (a.startsWith("Bearer ")) return a.slice(7);

  const b: any = (req as any).body;
  if (b && typeof b.k === "string") return b.k;
  if (b && typeof b.tenantKey === "string") return b.tenantKey;

  return "";
}

/**
 * Backward-compatible requireTenantKey:
 * - requireTenantKey(req, tenantId)
 * - requireTenantKey(req, tenantId, tenants, shares)  (ignored)
 * - requireTenantKey(req, tenantId, tenants)
 * returns tenantKey string or throws HttpError
 */
export function requireTenantKey(req: Request, tenantId: string, _tenants?: any, _shares?: any): string {
  const k = extractTenantKey(req);
  if (!k) throw new HttpError(401, "missing_tenant_key", "Missing tenant key");

  const ok = verifyTenantKeyLocal(tenantId, k);
  if (!ok) throw new HttpError(401, "invalid_tenant_key", "Bad tenant key");

  return k;
}
