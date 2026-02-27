#!/usr/bin/env bash
set -euo pipefail
TENANT_ID="${TENANT_ID:-tenant_demo}"
DATA_DIR="${DATA_DIR:-./data}"

node <<'NODE'
const fs = require("fs");
const path = require("path");

const tenantId = process.env.TENANT_ID || "tenant_demo";
const dataDir = path.resolve(process.env.DATA_DIR || "./data");
const reg = path.join(dataDir, "tenants", "registry.json");

if (!fs.existsSync(reg)) {
  console.error("registry_missing:", reg);
  process.exit(2);
}
const arr = JSON.parse(fs.readFileSync(reg,"utf8"));
const t = (Array.isArray(arr) ? arr : []).find(x => x.tenantId === tenantId);
if (!t) {
  console.error("tenant_missing:", tenantId);
  process.exit(3);
}
process.stdout.write(String(t.tenantKey || "") + "\n");
NODE
