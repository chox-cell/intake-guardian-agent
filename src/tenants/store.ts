import fs from "fs";
import path from "path";
import { nanoid } from "nanoid";

export type TenantRecord = {
  tenantId: string;
  tenantKey: string;
  createdAt: string;
  rotatedAt?: string;
};

function safeWriteJson(filePath: string, data: unknown) {
  const dir = path.dirname(filePath);
  fs.mkdirSync(dir, { recursive: true }); // ✅ mkdir the folder, not the file path
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2) + "\n", "utf8");
}

function safeReadJson<T>(filePath: string, fallback: T): T {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    const raw = fs.readFileSync(filePath, "utf8");
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export class TenantsStore {
  private filePath: string;
  private map: Map<string, TenantRecord>;

  constructor(opts: { dataDir: string }) {
    this.filePath = path.resolve(opts.dataDir, "tenants.json");
    const list = safeReadJson<TenantRecord[]>(this.filePath, []);
    // Normalize persisted shape (array or {tenants:[]}) and avoid runtime crash
const norm = Array.isArray(list) ? list : (list && Array.isArray((list as any).tenants) ? (list as any).tenants : []);
this.map = new Map(norm.map((t: any) => [t.tenantId, t]));
// persist to ensure file exists + normalized
    this.persist();
  }

  list(): TenantRecord[] {
    return Array.from(this.map.values()).sort((a, b) =>
      String(a.createdAt ?? "").localeCompare(String(b.createdAt ?? ""))
    );
  }

  get(tenantId: string): TenantRecord | undefined {
    return this.map.get(tenantId);
  }

  verify(tenantId: string, tenantKey: string): boolean {
    const t = this.map.get(tenantId);
    if (!t) return false;
    return t.tenantKey === tenantKey;
  }

  upsertNew(tenantId?: string) {
    const id = tenantId?.trim() || `tenant_${Date.now()}`;
    const now = new Date().toISOString();
    const rec: TenantRecord = {
      tenantId: id,
      tenantKey: nanoid(32),
      createdAt: now
    };
    this.map.set(id, rec);
    this.persist();
    return { tenantId: rec.tenantId, tenantKey: rec.tenantKey };
  }

  rotate(tenantId: string) {
    const t = this.map.get(tenantId);
    if (!t) return { ok: false as const, error: "tenant_not_found" as const };
    t.tenantKey = nanoid(32);
    t.rotatedAt = new Date().toISOString();
    this.map.set(tenantId, t);
    this.persist();
    return { ok: true as const, tenantId, tenantKey: t.tenantKey };
  }

  persist() {
    safeWriteJson(this.filePath, this.list());
  }
}
