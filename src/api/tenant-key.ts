import type { Request } from "express";

type TenantKeyMap = Record<string, string>;

let cachedRaw = "";
let cachedMap: TenantKeyMap = {};

function parseTenantKeys(): TenantKeyMap {
  const raw = process.env.TENANT_KEYS_JSON || "";
  if (raw === cachedRaw) return cachedMap;

  cachedRaw = raw;
  if (!raw.trim()) {
    cachedMap = {};
    return cachedMap;
  }

  try {
    const obj = JSON.parse(raw);
    if (!obj || typeof obj !== "object") throw new Error("TENANT_KEYS_JSON not an object");

    const out: TenantKeyMap = {};
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
      if (typeof k === "string" && typeof v === "string" && k.trim() && v.trim()) {
        out[k] = v;
      }
    }
    cachedMap = out;
    return cachedMap;
  } catch {
    cachedMap = {};
    return cachedMap;
  }
}

export function requireTenantKey(req: Request, tenantId: string): { ok: true } | { ok: false; status: number; error: string } {
  const map = parseTenantKeys();

  // If no keys configured -> allow (dev convenience)
  if (Object.keys(map).length === 0) return { ok: true };

  const expected = map[tenantId];
  if (!expected) return { ok: false, status: 403, error: "tenant_not_allowed" };

  const got = (req.header("x-tenant-key") || req.header("X-Tenant-Key") || "").trim();
  if (!got) return { ok: false, status: 401, error: "missing_tenant_key" };
  if (got !== expected) return { ok: false, status: 401, error: "invalid_tenant_key" };

  return { ok: true };
}
