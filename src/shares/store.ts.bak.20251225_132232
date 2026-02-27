import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type ShareRecord = {
  token: string;
  tenantId: string;
  createdAt: string;
  expiresAt?: string;
};

function safeReadJson(p: string): any {
  try {
    if (!fs.existsSync(p)) return null;
    const raw = fs.readFileSync(p, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function safeWriteJson(p: string, data: any) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(data, null, 2), "utf8");
}

function nowISO() {
  return new Date().toISOString();
}

function randToken(len = 32) {
  return crypto.randomBytes(len).toString("base64url");
}

/**
 * ShareStore is a tiny token service:
 * - create(tenantId) => { token }
 * - get(token) => ShareRecord | null
 * - verify(tenantId, token) => boolean
 */
export class ShareStore {
  private filePath: string;
  private shares: Record<string, ShareRecord>;

  constructor(dataDir = "./data") {
    this.filePath = path.join(dataDir, "shares.json");
    const j = safeReadJson(this.filePath);
    this.shares = (j && typeof j === "object" && j.shares) ? j.shares : {};
  }

  private persist() {
    safeWriteJson(this.filePath, { shares: this.shares });
  }

  create(tenantId: string, ttlSeconds: number = 60 * 60 * 24 * 30) {
    const token = randToken(18);
    const rec: ShareRecord = {
      token,
      tenantId,
      createdAt: nowISO(),
      expiresAt: new Date(Date.now() + ttlSeconds * 1000).toISOString(),
    };
    this.shares[token] = rec;
    this.persist();
    return { token };
  }

  get(token: string): ShareRecord | null {
    const rec = this.shares[token];
    if (!rec) return null;
    if (rec.expiresAt && Date.parse(rec.expiresAt) < Date.now()) return null;
    return rec;
  }

  verify(tenantId: string, token: string): boolean {
    const rec = this.get(token);
    return !!rec && rec.tenantId === tenantId;
  }
}
