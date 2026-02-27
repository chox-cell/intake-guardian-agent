const fs = require("fs");
const path = require("path");

const dataDir = process.env.DATA_DIR || "./data";
const tenantId = process.env.TENANT_ID || "demo";

function readJson(p){ return JSON.parse(fs.readFileSync(p,"utf8")); }
function pickKey(o){
  if (!o || typeof o !== "object") return null;
  if (typeof o === "string") return o;
  for (const k of ["key","apiKey","token","secret","tenantKey"]) {
    if (typeof o[k] === "string") return o[k];
  }
  return null;
}
function resolveDemoTenantId(reg){
  if (!reg || typeof reg !== "object") return null;
  const d = reg[tenantId];
  if (typeof d === "string") return d;
  if (d && typeof d === "object") {
    if (typeof d.tenantId === "string") return d.tenantId;
    if (typeof d.id === "string") return d.id;
    if (typeof d.slug === "string") return d.slug;
  }
  if (reg.tenants && typeof reg.tenants === "object" && !Array.isArray(reg.tenants)) {
    const t = reg.tenants[tenantId];
    if (typeof t === "string") return t;
    if (t && typeof t === "object") {
      if (typeof t.tenantId === "string") return t.tenantId;
      if (typeof t.id === "string") return t.id;
      if (typeof t.slug === "string") return t.slug;
    }
  }
  if (Array.isArray(reg.entries)) {
    const hit = reg.entries.find(x => x && (x.tenantId===tenantId || x.id===tenantId || x.slug===tenantId));
    if (hit) return hit.tenantId || hit.id || hit.slug || null;
  }
  return null;
}
function findKey(keysJson, resolvedTenantId){
  if (!keysJson || typeof keysJson !== "object") return null;
  const direct = keysJson[resolvedTenantId];
  let k = pickKey(direct); if (k) return k;
  const tenants = keysJson.tenants;
  if (tenants && typeof tenants === "object" && !Array.isArray(tenants)) {
    k = pickKey(tenants[resolvedTenantId]); if (k) return k;
  }
  if (Array.isArray(tenants)) {
    const hit = tenants.find(x => x && (x.tenantId===resolvedTenantId || x.id===resolvedTenantId || x.slug===resolvedTenantId));
    if (hit){ k = pickKey(hit); if (k) return k; }
  }
  for (const b of ["keys","tenantKeys"]) {
    const bucket = keysJson[b];
    if (bucket && typeof bucket === "object" && !Array.isArray(bucket)) {
      k = pickKey(bucket[resolvedTenantId]); if (k) return k;
    }
    if (Array.isArray(bucket)) {
      const hit = bucket.find(x => x && (x.tenantId===resolvedTenantId || x.id===resolvedTenantId || x.slug===resolvedTenantId));
      if (hit){ k = pickKey(hit); if (k) return k; }
    }
  }
  return null;
}

try {
  const regPath = path.join(dataDir,"tenant_registry.json");
  const keysPath = path.join(dataDir,"tenant_keys.json");
  if (!fs.existsSync(regPath) || !fs.existsSync(keysPath)) process.exit(1);
  const reg = readJson(regPath);
  const tid = resolveDemoTenantId(reg);
  if (!tid) process.exit(2);
  const keysJson = readJson(keysPath);
  const key = findKey(keysJson, tid);
  if (!key) process.exit(3);
  process.stdout.write(String(key));
} catch { process.exit(9); }
