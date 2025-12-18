import fs from "fs";
import path from "path";
import { Store } from "./store.js";
import { AuditEvent, WorkItem, Status } from "../types/contracts.js";

type Index = {
  workitems: WorkItem[];
  workById: Map<string, WorkItem>;
  auditByWorkId: Map<string, AuditEvent[]>;
};

export class FileStore implements Store {
  private dir: string;
  private workPath: string;
  private auditPath: string;

  private idx: Index = {
    workitems: [],
    workById: new Map(),
    auditByWorkId: new Map()
  };

  constructor(dataDir: string) {
    this.dir = dataDir;
    this.workPath = path.join(this.dir, "workitems.jsonl");
    this.auditPath = path.join(this.dir, "audit.jsonl");
  }

  async init(): Promise<void> {
    fs.mkdirSync(this.dir, { recursive: true });
    if (!fs.existsSync(this.workPath)) fs.writeFileSync(this.workPath, "", "utf8");
    if (!fs.existsSync(this.auditPath)) fs.writeFileSync(this.auditPath, "", "utf8");
    this.loadWorkItems();
    this.loadAudit();
  }

  private loadWorkItems() {
    const lines = fs.readFileSync(this.workPath, "utf8").split("\n").filter(Boolean);
    for (const line of lines) {
      try {
        const wi = JSON.parse(line) as WorkItem;
        this.idx.workitems.push(wi);
        this.idx.workById.set(this.key(wi.tenantId, wi.id), wi);
      } catch {}
    }
    this.idx.workitems.sort((a, b) => (b.updatedAt || b.createdAt).localeCompare(a.updatedAt || a.createdAt));
  }

  private loadAudit() {
    const lines = fs.readFileSync(this.auditPath, "utf8").split("\n").filter(Boolean);
    for (const line of lines) {
      try {
        const ev = JSON.parse(line) as AuditEvent;
        const k = this.key(ev.tenantId, ev.workItemId);
        const arr = this.idx.auditByWorkId.get(k) ?? [];
        arr.push(ev);
        this.idx.auditByWorkId.set(k, arr);
      } catch {}
    }
  }

  private appendLine(filePath: string, obj: any) {
    fs.appendFileSync(filePath, JSON.stringify(obj) + "\n", "utf8");
  }

  private key(tenantId: string, id: string) {
    return `${tenantId}::${id}`;
  }

  async createWorkItem(item: WorkItem): Promise<void> {
    this.appendLine(this.workPath, item);
    this.idx.workitems.unshift(item);
    this.idx.workById.set(this.key(item.tenantId, item.id), item);
  }

  async getWorkItem(tenantId: string, id: string): Promise<WorkItem | null> {
    return this.idx.workById.get(this.key(tenantId, id)) ?? null;
  }

  async listWorkItems(
    tenantId: string,
    q: { status?: Status; limit?: number; offset?: number; search?: string }
  ): Promise<WorkItem[]> {
    const limit = Math.min(q.limit ?? 50, 200);
    const offset = q.offset ?? 0;
    const search = (q.search ?? "").toLowerCase().trim();

    const filtered = this.idx.workitems.filter((w) => {
      if (w.tenantId !== tenantId) return false;
      if (q.status && w.status !== q.status) return false;
      if (search) {
        const hay = `${w.normalizedBody} ${w.sender} ${w.subject ?? ""}`.toLowerCase();
        if (!hay.includes(search)) return false;
      }
      return true;
    });

    return filtered.slice(offset, offset + limit);
  }

  async findByFingerprint(tenantId: string, fingerprint: string, windowSeconds: number): Promise<WorkItem | null> {
    const sinceMs = Date.now() - windowSeconds * 1000;
    for (const w of this.idx.workitems) {
      if (w.tenantId !== tenantId) continue;
      if (w.fingerprint !== fingerprint) continue;
      const createdMs = Date.parse(w.createdAt);
      if (!Number.isFinite(createdMs)) continue;
      if (createdMs >= sinceMs) return w;
    }
    return null;
  }

  async updateStatus(tenantId: string, id: string, next: Status): Promise<void> {
    const k = this.key(tenantId, id);
    const cur = this.idx.workById.get(k);
    if (!cur) return;

    const updated: WorkItem = { ...cur, status: next, updatedAt: new Date().toISOString() };
    this.appendLine(this.workPath, updated);

    this.idx.workById.set(k, updated);
    this.idx.workitems = this.idx.workitems.map((w) => (w.tenantId === tenantId && w.id === id ? updated : w));
  }

  async assignOwner(tenantId: string, id: string, ownerId: string | null): Promise<void> {
    const k = this.key(tenantId, id);
    const cur = this.idx.workById.get(k);
    if (!cur) return;

    const updated: WorkItem = { ...cur, ownerId: ownerId ?? undefined, updatedAt: new Date().toISOString() };
    this.appendLine(this.workPath, updated);

    this.idx.workById.set(k, updated);
    this.idx.workitems = this.idx.workitems.map((w) => (w.tenantId === tenantId && w.id === id ? updated : w));
  }

  async appendAudit(ev: AuditEvent): Promise<void> {
    this.appendLine(this.auditPath, ev);
    const k = this.key(ev.tenantId, ev.workItemId);
    const arr = this.idx.auditByWorkId.get(k) ?? [];
    arr.push(ev);
    this.idx.auditByWorkId.set(k, arr);
  }

  async listAudit(tenantId: string, workItemId: string, limit: number = 200): Promise<AuditEvent[]> {
    const k = this.key(tenantId, workItemId);
    const arr = this.idx.auditByWorkId.get(k) ?? [];
    return arr.slice(Math.max(0, arr.length - Math.min(limit, 1000)));
  }
}
