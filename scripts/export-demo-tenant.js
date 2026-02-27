const fs = require("fs");

const KEYS = process.env.DATA_DIR ? `${process.env.DATA_DIR.replace(/\/$/,'')}/tenant_keys.json` : "./data/tenant_keys.json";
const TENANT_ID = process.env.TENANT_ID || process.argv[2] || "tenant_1766927347649_12ef20a5147c";

const j = JSON.parse(fs.readFileSync(KEYS, "utf8"));
const t = j.tenants?.[TENANT_ID];

if (!t || !t.tenantKey) {
  console.error("FAIL: tenant not found in tenant_keys.json for TENANT_ID=" + TENANT_ID);
  process.exit(1);
}

const key = String(t.tenantKey);
process.stdout.write(`export TENANT_ID=${JSON.stringify(TENANT_ID)}\n`);
process.stdout.write(`export TENANT_KEY_DEMO=${JSON.stringify(key)}\n`);
process.stdout.write(`export TENANT_KEYS_JSON=${JSON.stringify(JSON.stringify({ [TENANT_ID]: key }))}\n`);
process.stdout.write(`export TENANT_KEYS=${JSON.stringify(JSON.stringify({ [TENANT_ID]: key }))}\n`);
