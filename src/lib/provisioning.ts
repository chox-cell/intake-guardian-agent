import crypto from "node:crypto";
import { AuthStore } from "./auth_store";
import { getOrCreateDemoTenant, upsertTenantRecord, type TenantRecord } from "./tenant_registry";

function nowUtc() { return new Date().toISOString(); }

function randKey32() {
  // 32 chars (hex 16 bytes) => 32 length
  return crypto.randomBytes(16).toString("hex");
}

export type Provisioned = {
  workspaceId: string;
  tenant: TenantRecord;
  userEmail: string;
};

export function provisionWorkspaceForEmail(email: string, dataDir?: string): Provisioned {
  const workspaceId = `ws_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantId = `tenant_${Date.now()}_${crypto.randomBytes(6).toString("hex")}`;
  const tenantKey = randKey32();

  // write tenant to registry.json (no secrets printed by helper)
  
upsertTenantRecord({ tenantId, tenantKey, notes: `provisioned:` }, dataDir);

  // create/attach user
  const as = new AuthStore(dataDir);
  as.getOrCreateUserByEmail(email, workspaceId, tenantId);

  return {
    workspaceId,
    tenant: { tenantId, tenantKey, notes: `provisioned:`, createdAtUtc: nowUtc(), updatedAtUtc: nowUtc() },
    userEmail: email.trim().toLowerCase(),
  };
}

// Optional helper: ensure demo tenant exists (for local quick start)
export function ensureDemoTenant(dataDir?: string) {
  return getOrCreateDemoTenant(dataDir);
}
