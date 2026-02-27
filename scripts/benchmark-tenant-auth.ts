
import path from "node:path";
import fs from "node:fs";
import { verifyTenantKeyLocal, createTenant } from "../src/lib/tenant_registry";

const DATA_DIR = "./bench-data";

// Setup
if (fs.existsSync(DATA_DIR)) {
  fs.rmSync(DATA_DIR, { recursive: true, force: true });
}
fs.mkdirSync(DATA_DIR);

const tenant = createTenant(DATA_DIR, "Bench Tenant");
const tenantId = tenant.tenantId;
const tenantKey = tenant.tenantKey;

console.log(`Setup: Tenant ${tenantId} created in ${DATA_DIR}`);

const ITERATIONS = 1000;

console.log(`Starting benchmark: ${ITERATIONS} iterations of verifyTenantKeyLocal...`);

const start = performance.now();
for (let i = 0; i < ITERATIONS; i++) {
  const ok = verifyTenantKeyLocal(tenantId, tenantKey, DATA_DIR);
  if (!ok) throw new Error("Verification failed during benchmark");
}
const end = performance.now();

const duration = end - start;
const opsPerSec = (ITERATIONS / duration) * 1000;

console.log(`Total time: ${duration.toFixed(2)}ms`);
console.log(`Ops/sec: ${opsPerSec.toFixed(2)}`);
console.log(`Avg time per op: ${(duration / ITERATIONS).toFixed(4)}ms`);

// Cleanup
fs.rmSync(DATA_DIR, { recursive: true, force: true });
