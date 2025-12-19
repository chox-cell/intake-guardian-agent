import fs from "fs";
import path from "path";
import crypto from "crypto";

export type TenantRecord = {
  tenantId: string;
  tenantKeyHash: string; // sha256
  createdAt: string;
  rotatedAt?: string;
};

export function hashKey(k: string) {
  return crypto.createHash("sha256").update(k).digest("hex");
}

export function generateKey(len = 32) {
  // url-safe-ish
  return crypto.randomBytes(Math.ceil(len)).toString("base64url").slice(0, len);
}

export class TenantsStore {
  private filePath: string;
  private cache: Record<string, TenantRecord> = {};
  private loaded = false;

  constructor(args: { dataDir: string }) {
    this.filePath = path.resolve(args.dataDir, "tenants.json");
  }

  private loadIfNeeded() {
    if (this.loaded) return;
    this.loaded = true;
    if (!fs.existsSync(this.filePath)) {
      this.cache = {};
      return;
    }
    const raw = fs.readFileSync(this.filePath, "utf-8").trim();
    if (!raw) { this.cache = {}; return; }
    this.cache = JSON.parse(raw);
  }

  private persist() {
    const dir = path.dirname(this.filePath);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(this.filePath, JSON.stringify(this.cache, null, 2) + "\n", "utf-8");
  }

  list() {
    this.loadIfNeeded();
    return Object.values(this.cache).sort((a,b)=> (a.createdAt < b.createdAt ? 1 : -1));
  }

  get(tenantId: string) {
    this.loadIfNeeded();
    return this.cache[tenantId] || null;
  }

  upsertNew(tenantId: string) {
    this.loadIfNeeded();
    if (this.cache[tenantId]) {
      return { created: false, tenantId, tenantKey: null as string | null };
    }
    const tenantKey = generateKey(32);
    this.cache[tenantId] = {
      tenantId,
      tenantKeyHash: hashKey(tenantKey),
      createdAt: new Date().toISOString()
    };
    this.persist();
    return { created: true, tenantId, tenantKey };
  }

  rotate(tenantId: string) {
    this.loadIfNeeded();
    if (!this.cache[tenantId]) return { ok: false as const, error: "tenant_not_found" as const };
    const tenantKey = generateKey(32);
    this.cache[tenantId] = {
      ...this.cache[tenantId],
      tenantKeyHash: hashKey(tenantKey),
      rotatedAt: new Date().toISOString()
    };
    this.persist();
    return { ok: true as const, tenantId, tenantKey };
  }

  verify(tenantId: string, tenantKey: string) {
    this.loadIfNeeded();
    const rec = this.cache[tenantId];
    if (!rec) return false;
    return hashKey(tenantKey) === rec.tenantKeyHash;
  }
}
