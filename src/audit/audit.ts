import { nanoid } from "nanoid";
import { AuditEvent } from "../types/contracts.js";

export function makeAudit(args: {
  tenantId: string;
  workItemId: string;
  type: string;
  actor?: string;
  payload?: Record<string, unknown>;
}): AuditEvent {
  return {
    id: nanoid(),
    tenantId: args.tenantId,
    workItemId: args.workItemId,
    type: args.type,
    actor: args.actor ?? "system",
    payload: args.payload ?? {},
    at: new Date().toISOString()
  };
}
