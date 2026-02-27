import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

export type EvidenceItem = {
  tenantId: string;
  evidenceId: string;
  kind: string;
  createdAtUtc: string;
  sha256: string;
  payload: any;
};

function nowUtc() { return new Date().toISOString(); }
function id(prefix: string) { return `${prefix}_${crypto.randomBytes(12).toString("hex")}`; }

function sha256Json(v: any) {
  const h = crypto.createHash("sha256");
  h.update(Buffer.from(JSON.stringify(v)));
  return h.digest("hex");
}

export class EvidenceStore {
  private root: string;

  constructor(dataDir: string) {
    this.root = path.join(dataDir, "decision_cover", "evidence");
    fs.mkdirSync(this.root, { recursive: true });
  }

  private fileForTenant(tenantId: string) {
    return path.join(this.root, `${tenantId}.jsonl`);
  }

  append(tenantId: string, kind: string, payload: any): EvidenceItem {
    const item: EvidenceItem = {
      tenantId,
      evidenceId: id("e"),
      kind,
      createdAtUtc: nowUtc(),
      sha256: sha256Json(payload),
      payload,
    };
    fs.appendFileSync(this.fileForTenant(tenantId), JSON.stringify(item) + "\n", "utf8");
    return item;
  }

  list(tenantId: string): EvidenceItem[] {
    const f = this.fileForTenant(tenantId);
    if (!fs.existsSync(f)) return [];
    const lines = fs.readFileSync(f, "utf8").split("\n").filter(Boolean);
    const out: EvidenceItem[] = [];
    for (const ln of lines) {
      try { out.push(JSON.parse(ln)); } catch {}
    }
    return out;
  }

  getById(tenantId: string, evidenceId: string): EvidenceItem | null {
    const items = this.list(tenantId);
    for (let i = items.length - 1; i >= 0; i--) {
      if (items[i].evidenceId === evidenceId) return items[i];
    }
    return null;
  }
}
