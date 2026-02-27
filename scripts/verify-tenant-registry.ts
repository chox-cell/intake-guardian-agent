
import path from "node:path";
import fs from "node:fs";
import { verifyTenantKeyLocal, createTenant, listTenants } from "../src/lib/tenant_registry";

const DATA_DIR = "./verify-data";

// Setup
if (fs.existsSync(DATA_DIR)) {
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
}
fs.mkdirSync(DATA_DIR);

const tenant = createTenant(DATA_DIR, "Verify Tenant");
const tenantId = tenant.tenantId;
const tenantKey = tenant.tenantKey;

console.log(`Setup: Tenant ${tenantId} created in ${DATA_DIR}`);

// Verify
const tenants = listTenants(DATA_DIR);
if (tenants.length !== 1) {
  throw new Error(`Expected 1 tenant, got ${tenants.length}`);
}
if (tenants[0].tenantId !== tenantId) {
  throw new Error(`Expected tenantId ${tenantId}, got ${tenants[0].tenantId}`);
}

const ok = verifyTenantKeyLocal(tenantId, tenantKey, DATA_DIR);
if (!ok) {
  throw new Error("Verification failed after creation");
}

console.log("Verification passed: create, list, and verify work correctly.");

// Cleanup
fs.rmSync(DATA_DIR, { recursive: true, force: true });
