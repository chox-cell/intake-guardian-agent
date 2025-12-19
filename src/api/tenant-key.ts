import type { Request } from "express";
import { z } from "zod";
import type { TenantsStore } from "../tenants/store.js";

function parseTenantKeysJson(): Record<string, string> {
  const raw = (process.env.TENANT_KEYS_JSON || "").trim();
  if (!raw) return {};
  // allow either plain JSON or quoted JSON string
  let v = raw;
  if ((v.startsWith("'") && v.endsWith("'")) || (v.startsWith('"') && v.endsWith('"'))) v = v.slice(1, -1);
  try {
    return z.record(z.string(), z.string()).parse(JSON.parse(v));
  } catch {
    return {};
  }
}

export function requireTenantKey(req: Request, tenantId: string, tenantsStore?: TenantsStore) {
  const key = (req.header("x-tenant-key") || "").trim();
  if (!key) return { ok: false as const, status: 401, error: "missing_tenant_key" as const };

  // 1) Prefer TenantsStore if provided (file-based keys)
  if (tenantsStore) {
    const ok = tenantsStore.verify(tenantId, key);
    if (ok) return { ok: true as const };
  }

  // 2) Fallback to TENANT_KEYS_JSON (back-compat)
  const m = parseTenantKeysJson();
  if (m[tenantId] && m[tenantId] === key) return { ok: true as const };

  return { ok: false as const, status: 403, error: "invalid_tenant_key" as const };
}
