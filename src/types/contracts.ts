export type Source = "email" | "whatsapp" | "form" | "api";
export type Priority = "low" | "normal" | "high" | "critical";
export type Status = "new" | "triage" | "in_progress" | "waiting" | "resolved" | "closed";

export interface InboundEvent {
  tenantId: string;
  source: Source;
  sender: string;
  subject?: string;
  body: string;
  meta?: Record<string, unknown>;
  receivedAt: string; // ISO
}

export interface WorkItem {
  id: string;
  tenantId: string;
  source: Source;
  sender: string;
  subject?: string;
  rawBody: string;
  normalizedBody: string;
  category: string;
  priority: Priority;
  status: Status;
  ownerId?: string;
  slaSeconds: number;
  dueAt?: string; // ISO
  tags: string[];
  fingerprint: string;
  presetId: string;
  createdAt: string; // ISO
  updatedAt: string; // ISO
}

export interface AuditEvent {
  id: string;
  tenantId: string;
  workItemId: string;
  type: string;
  actor: string; // "system" in v1
  payload: Record<string, unknown>;
  at: string; // ISO
}
