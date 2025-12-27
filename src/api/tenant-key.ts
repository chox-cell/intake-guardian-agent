import type { Request } from "express";
import type { TenantsStore } from "../tenants/store.js";

function safeJson(s: string) {
  try { return JSON.parse(s); } catch { return null; }
}

function getKeyFromReq(req: Request): string {
  const h = (req.header("x-tenant-key") || "").trim();
  if (h) return h;

  // UI links: /ui/...?k=TENANT_KEY
  const q = (typeof req.query.k === "string" ? req.query.k : "").trim();
  if (q) return q;

  // optional: body.k
  const b = (req.body && typeof (req.body as any).k === "string" ? (req.body as any).k : "").trim();
  if (b) return b;

  return "";
}

export function requireTenantKey(req: Request, tenantId: string, tenantsStore?: TenantsStore, _ignored?: any) {
  const key = getKeyFromReq(req);

  if (!key) {
    return { ok: false as const, status: 401, error: "missing_tenant_key" as const };
  }

  // Preferred: TenantsStore (dynamic tenants created via admin)
  if (tenantsStore) {
    const ok = tenantsStore.verify(tenantId, key);
    if (!ok) return { ok: false as const, status: 401, error: "invalid_tenant_key" as const };
    return { ok: true as const, status: 200, key };
  }

  // Fallback: TENANT_KEYS_JSON for dev
  const raw = (process.env.TENANT_KEYS_JSON || "").trim();
  if (!raw) {
    return { ok: false as const, status: 500, error: "tenant_keys_not_configured" as const };
  }
  const obj = safeJson(raw);
  const expected = obj && typeof obj[tenantId] === "string" ? String(obj[tenantId]) : "";
  if (!expected || expected !== key) {
    return { ok: false as const, status: 401, error: "invalid_tenant_key" as const };
  }
  return { ok: true as const, status: 200, key };
}
