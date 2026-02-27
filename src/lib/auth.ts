import type { Request } from "express";

export function tenantIdFromReq(req: Request): string {
  const q = req.query as any;
  return String(q.tenantId || "").trim();
}

export function tenantKeyFromReq(req: Request): string {
  const q = req.query as any;
  // Accept:
  // - header x-tenant-key (preferred for webhooks)
  // - query k (for client UI links)
  const h = String(req.headers["x-tenant-key"] || "").trim();
  if (h) return h;
  return String(q.k || "").trim();
}

export function hasTenantAuth(req: Request): { ok: boolean; tenantId: string; tenantKey: string; hint?: string } {
  const tenantId = tenantIdFromReq(req);
  const tenantKey = tenantKeyFromReq(req);
  if (!tenantId) return { ok: false, tenantId, tenantKey, hint: "missing tenantId" };
  if (!tenantKey) return { ok: false, tenantId, tenantKey, hint: "missing tenant key (header x-tenant-key or query k)" };
  return { ok: true, tenantId, tenantKey };
}
