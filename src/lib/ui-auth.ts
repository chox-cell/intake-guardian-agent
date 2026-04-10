import type { Request, Response, NextFunction } from "express";
import { verifyTenantKeyLocal } from "./tenant_registry.js";

/**
 * Enterprise-safe Stateless UI Auth
 * - No cookies
 * - No sessions
 * - Works with Zapier/Make links: ?tenantId=...&k=...
 */
export function uiAuth(req: Request, res: Response, next: NextFunction) {
  const q = req.query as any;
  const tenantId = String(q?.tenantId || "").trim();
  const k = String(q?.k || "").trim();
  if (!tenantId || !k) {
    return res.status(401).send("Missing tenantId or k");
  }

  // Security Check: Validate credentials against SSOT tenant registry
  if (!verifyTenantKeyLocal(tenantId, k)) {
    return res.status(403).send("Forbidden: Invalid tenantId or k");
  }

  (req as any).auth = { tenantId, k };
  return next();
}
