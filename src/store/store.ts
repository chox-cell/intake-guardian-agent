import { AuditEvent, WorkItem, Status } from "../types/contracts.js";

export interface Store {
  init(): Promise<void>;

  createWorkItem(item: WorkItem): Promise<void>;
  getWorkItem(tenantId: string, id: string): Promise<WorkItem | null>;
  listWorkItems(tenantId: string, q: {
    status?: Status;
    limit?: number;
    offset?: number;
    search?: string;
  }): Promise<WorkItem[]>;

  findByFingerprint(tenantId: string, fingerprint: string, windowSeconds: number): Promise<WorkItem | null>;

  updateStatus(tenantId: string, id: string, next: Status): Promise<void>;
  assignOwner(tenantId: string, id: string, ownerId: string | null): Promise<void>;

  appendAudit(ev: AuditEvent): Promise<void>;
  listAudit(tenantId: string, workItemId: string, limit?: number): Promise<AuditEvent[]>;
}
